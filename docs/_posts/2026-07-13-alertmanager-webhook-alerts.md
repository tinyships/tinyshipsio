---
layout: post
title: "Alerting on OpenShift Workloads with AlertManager and a Webhook Receiver"
date: 2026-07-13
---

OpenShift ships with a full monitoring stack — Prometheus, AlertManager, and the built-in Observe console — but by default it only monitors platform components. Your own workloads do not get alerting rules unless you set them up. This is a quick why and how-to for enabling user-workload monitoring, writing PrometheusRule alert definitions, and routing those alerts to a webhook receiver using AlertManager — all self-contained on a single cluster.

## Why This Matters

Monitoring and logging tell you what happened. Alerting tells you it is happening — right now, while you can still do something about it. That distinction matters more than most teams appreciate when they are first building out their observability stack.

OpenShift already has AlertManager running in `openshift-monitoring`. It handles platform alerts out of the box — things like etcd latency, node pressure, and API server errors. But it does not watch your application namespaces unless you explicitly opt in. That means your workloads can restart, exhaust memory, or throw errors for hours before anyone notices — unless someone happens to be watching a dashboard.

The mechanism for closing that gap is user-workload monitoring. Once enabled, OpenShift deploys a second Prometheus instance in `openshift-user-workload-monitoring` that scrapes metrics from your namespaces. You define alert rules with `PrometheusRule` resources and route them with `AlertmanagerConfig` resources — both living in your project namespace, both manageable without cluster-admin privileges. The alerts flow through the platform AlertManager and reach whatever receiver you configure: email, Slack, PagerDuty, or a simple webhook.

This post uses a webhook receiver because it makes the entire pipeline visible. You can watch the alert fire, see the JSON payload arrive, and understand exactly what AlertManager sends downstream. Once that works, swapping in a production receiver is a configuration change, not an architecture change.

---

## The Steps

1. Enable user-workload monitoring and alert routing on the cluster
2. Deploy the `logspam` log generator as a sample workload
3. Deploy a webhook receiver that catches and displays alert payloads
4. Create a `PrometheusRule` with three alert definitions — a test alert, a container restart alert, and a high memory alert
5. Create an `AlertmanagerConfig` to route alerts from the `logspam` namespace to the webhook receiver
6. Trigger an alert and verify it arrives at the webhook

---

## How To Do It

### Step 1: Enable User-Workload Monitoring

OpenShift disables user-workload monitoring by default. Enabling it requires a ConfigMap in the `openshift-monitoring` namespace. This is a cluster-admin operation — once it is done, individual teams can create their own alerting rules without admin help.

📄 [1-enable-user-workload-monitoring.yaml](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/alertmanager-webhook-alerts/1-enable-user-workload-monitoring.yaml)

```bash
oc apply -f 1-enable-user-workload-monitoring.yaml
```

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
    alertmanagerMain:
      enableUserAlertmanagerConfig: true
```

Two settings are at play here:

- **`enableUserWorkload: true`** tells the Cluster Monitoring Operator (CMO) to deploy a dedicated Prometheus instance and Thanos Ruler in the `openshift-user-workload-monitoring` namespace. This Prometheus scrapes `ServiceMonitor` and `PodMonitor` resources from user namespaces, and Thanos Ruler evaluates `PrometheusRule` resources.
- **`alertmanagerMain.enableUserAlertmanagerConfig: true`** allows users to create `AlertmanagerConfig` resources in their own namespaces. Without this, user-defined PrometheusRules can fire alerts, but there is no way to route them to custom receivers — they only show up in the OpenShift console.

> If a `cluster-monitoring-config` ConfigMap already exists on your cluster, merge these keys into the existing `config.yaml` rather than replacing the whole ConfigMap. Overwriting it could remove settings another team depends on.

Verify that the user-workload monitoring pods come up in the new namespace:

```bash
oc get pods -n openshift-user-workload-monitoring
```

```
NAME                                   READY   STATUS    RESTARTS   AGE
prometheus-operator-8697fc5f77-j9gv8   2/2     Running   0          45s
prometheus-user-workload-0             6/6     Running   0          40s
thanos-ruler-user-workload-0           4/4     Running   0          35s
```

On HA clusters you will see two replicas of `prometheus-user-workload` and `thanos-ruler-user-workload` — compact or single-node clusters deploy one of each. All pods need to be `Running` before continuing. They may take 30-60 seconds to start.

---

### Step 2: Deploy the Log Generator

This is the same `logspam` workload used in the [syslog forwarding post](/2026/04/03/forwarding-openshift-logs-syslog.html) — a UBI 9 container running a shell loop that emits log messages at random levels and intervals. If you already have it running from that post, skip this step.

📄 [2-logspam-with-metrics.yaml](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/alertmanager-webhook-alerts/2-logspam-with-metrics.yaml)

```bash
oc apply -f 2-logspam-with-metrics.yaml
```

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: logspam
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: log-generator
  namespace: logspam
spec:
  replicas: 1
  selector:
    matchLabels:
      app: log-generator
  template:
    metadata:
      labels:
        app: log-generator
    spec:
      containers:
      - name: log-generator
        image: registry.access.redhat.com/ubi9/ubi:latest
        command: ["/bin/bash", "-c"]
        args:
        - |
          trap 'echo "[ERROR] Received crash signal, exiting" && exit 1' USR1
          LEVELS=("INFO" "WARN" "ERROR" "DEBUG")
          MESSAGES=(
            "Application started successfully"
            "High memory usage detected: 85%"
            "Failed to connect to database - retrying"
            "Processing request ID $((RANDOM % 100000))"
            "Cache miss for key user-session-$((RANDOM % 999))"
            "Successfully flushed write buffer to disk"
            "Rate limit exceeded for client"
            "Scheduled job completed"
          )
          while true; do
            LEVEL=${LEVELS[$((RANDOM % 4))]}
            MSG=${MESSAGES[$((RANDOM % 8))]}
            echo "[${LEVEL}] ${MSG} at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
            sleep $((RANDOM % 5 + 1))
          done
```

The Namespace and Deployment are in a single file. The `trap` line at the top registers a signal handler — when the container receives `SIGUSR1`, it logs an error and exits with code 1. This gives you a clean way to crash the container on demand in Step 6 so kubelet restarts it and the restart counter increments. The container runs as whatever UID OpenShift assigns — no special security context needed.

Verify the pod is running:

```bash
oc get pods -n logspam -l app=log-generator
```

```
NAME                             READY   STATUS    RESTARTS   AGE
log-generator-7d6f9b8c4-xk2pj   1/1     Running   0          15s
```

Tail the logs briefly to confirm it is producing output:

```bash
oc logs -n logspam -l app=log-generator -f --tail=3
```

```
[WARN] High memory usage detected: 85% at 2026-07-13T14:23:41Z
[INFO] Application started successfully at 2026-07-13T14:23:44Z
[ERROR] Failed to connect to database - retrying at 2026-07-13T14:23:46Z
```

---

### Step 3: Deploy the Webhook Receiver

The webhook receiver is a lightweight Python HTTP server running inside a UBI 9 container. It listens on port 8080, accepts POST requests from AlertManager, parses the alert payload, and prints a formatted summary to stdout. That means you can see every alert that arrives by tailing the pod logs.

📄 [3-webhook-receiver.yaml](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/alertmanager-webhook-alerts/3-webhook-receiver.yaml)

```bash
oc apply -f 3-webhook-receiver.yaml
```

This file creates two resources:

#### Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webhook-receiver
  namespace: logspam
spec:
  replicas: 1
  selector:
    matchLabels:
      app: webhook-receiver
  template:
    metadata:
      labels:
        app: webhook-receiver
    spec:
      containers:
      - name: webhook-receiver
        image: registry.access.redhat.com/ubi9/ubi:latest
        command: ["python3", "-u", "-c"]
        args:
        - |
          import json
          from http.server import HTTPServer, BaseHTTPRequestHandler
          from datetime import datetime, timezone

          class WebhookHandler(BaseHTTPRequestHandler):
              def do_POST(self):
                  length = int(self.headers.get("Content-Length", 0))
                  body = self.rfile.read(length)
                  now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                  print("")
                  print("=" * 50)
                  print(f"  ALERT RECEIVED: {now}")
                  print("=" * 50)
                  try:
                      data = json.loads(body)
                      for alert in data.get("alerts", []):
                          status = alert.get("status", "unknown")
                          name = alert.get("labels", {}).get("alertname", "unknown")
                          severity = alert.get("labels", {}).get("severity", "unknown")
                          summary = alert.get("annotations", {}).get("summary", "")
                          desc = alert.get("annotations", {}).get("description", "")
                          print(f"  Status:      {status}")
                          print(f"  Alert:       {name}")
                          print(f"  Severity:    {severity}")
                          print(f"  Summary:     {summary}")
                          print(f"  Description: {desc}")
                          print("-" * 50)
                  except json.JSONDecodeError:
                      print(body.decode("utf-8", errors="replace"))
                  print("=" * 50)
                  print("")
                  self.send_response(200)
                  self.send_header("Content-Type", "text/plain")
                  self.end_headers()
                  self.wfile.write(b"OK")

              def log_message(self, format, *args):
                  pass

          print("Webhook receiver starting on port 8080...")
          HTTPServer(("", 8080), WebhookHandler).serve_forever()
```

The `-u` flag on `python3` disables output buffering so log lines appear in `oc logs` immediately instead of being held in a buffer. The `log_message` override silences the default HTTP access log — without it, every health check or alert POST would produce a noisy access log line alongside the formatted output.

#### Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: webhook-receiver
  namespace: logspam
spec:
  selector:
    app: webhook-receiver
  ports:
  - name: http
    port: 8080
    protocol: TCP
    targetPort: 8080
```

The `ClusterIP` service gives AlertManager a stable in-cluster DNS name: `webhook-receiver.logspam.svc.cluster.local:8080`. The `AlertmanagerConfig` in Step 5 references this URL.

Verify the webhook pod is running:

```bash
oc get pods -n logspam -l app=webhook-receiver
```

```
NAME                                READY   STATUS    RESTARTS   AGE
webhook-receiver-5f8b7c9d4-m2xkj   1/1     Running   0          10s
```

Test that it accepts HTTP requests:

```bash
oc exec -n logspam deploy/webhook-receiver -- curl -s -X POST http://localhost:8080 \
  -H "Content-Type: application/json" \
  -d '{"alerts":[{"status":"firing","labels":{"alertname":"TestAlert","severity":"info"},"annotations":{"summary":"Manual test","description":"This is a manual test."}}]}'
```

Then check the logs:

```bash
oc logs -n logspam -l app=webhook-receiver --tail=10
```

```
Webhook receiver starting on port 8080...

==================================================
  ALERT RECEIVED: 2026-07-13T14:25:12Z
==================================================
  Status:      firing
  Alert:       TestAlert
  Severity:    info
  Summary:     Manual test
  Description: This is a manual test.
--------------------------------------------------
==================================================
```

The receiver is working. Now it needs alerts to receive.

---

### Step 4: Create the PrometheusRule

A `PrometheusRule` defines alerting rules that the user-workload Prometheus evaluates. When an expression evaluates to true for the specified `for` duration, the alert transitions to `firing` and AlertManager picks it up.

📄 [4-prometheus-rule.yaml](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/alertmanager-webhook-alerts/4-prometheus-rule.yaml)

```bash
oc apply -f 4-prometheus-rule.yaml
```

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: logspam-alerts
  namespace: logspam
spec:
  groups:
  - name: logspam.rules
    rules:
    - alert: LogspamContainerRestarted
      expr: |
        increase(kube_pod_container_status_restarts_total{namespace="logspam"}[5m]) > 0
      for: 1m
      labels:
        severity: warning
        app: log-generator
      annotations:
        summary: "Container restart detected in logspam namespace"
        description: "Pod {{ $labels.pod }} in namespace {{ $labels.namespace }} has restarted in the last 5 minutes."
    - alert: LogspamHighMemory
      expr: |
        container_memory_working_set_bytes{namespace="logspam", container="log-generator"} > 100 * 1024 * 1024
      for: 2m
      labels:
        severity: critical
        app: log-generator
      annotations:
        summary: "High memory usage in logspam container"
        description: "Container {{ $labels.container }} in pod {{ $labels.pod }} is using more than 100Mi of memory."
    - alert: LogspamAlwaysFiring
      expr: vector(1)
      for: 1m
      labels:
        severity: info
        app: log-generator
      annotations:
        summary: "Test alert - always firing"
        description: "This alert always fires and is used to verify the alerting pipeline is working end-to-end."
```

Three rules are defined, each serving a different purpose:

- **LogspamAlwaysFiring** uses `vector(1)` — an expression that always evaluates to 1. This means the alert fires immediately (after the 1-minute `for` duration) and stays firing forever. It exists purely to verify the pipeline works end-to-end without waiting for a real event to happen. Remove it once you have confirmed alerts are flowing.

- **LogspamContainerRestarted** watches the `kube_pod_container_status_restarts_total` counter for pods in the `logspam` namespace. If the restart count increases at all within a 5-minute window and stays elevated for 1 minute, the alert fires. This is useful for catching crash loops or unexpected restarts.

- **LogspamHighMemory** fires when the log-generator container exceeds 100Mi of working set memory for 2 consecutive minutes. The log generator uses very little memory, so this alert exists to demonstrate a threshold-based rule — adjust the value downward if you want to see it fire during the demo.

The `labels` on each rule are important for routing. The `AlertmanagerConfig` in the next step matches on these labels to decide which receiver gets the alert.

Verify the rule was picked up by the user-workload Prometheus:

```bash
oc get prometheusrule logspam-alerts -n logspam
```

```
NAME             AGE
logspam-alerts   5s
```

Check the alert status in the OpenShift console under **Observe > Alerting**, or query the Thanos Ruler API directly:

```bash
TOKEN=$(oc whoami -t)
THANOS_HOST=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')
curl -sk -H "Authorization: Bearer $TOKEN" \
  "https://$THANOS_HOST/api/v1/rules" | \
  python3 -c "
import sys, json
data = json.load(sys.stdin)
for group in data.get('data', {}).get('groups', []):
    if group.get('name') == 'logspam.rules':
        for rule in group.get('rules', []):
            print(f\"  {rule['name']}: {rule['state']}\")
"
```

```
  LogspamContainerRestarted: inactive
  LogspamHighMemory: inactive
  LogspamAlwaysFiring: firing
```

The `LogspamAlwaysFiring` alert should show `firing` within 1-2 minutes. The other two should show `inactive` since no restarts or memory spikes have occurred yet.

---

### Step 5: Create the AlertmanagerConfig

An `AlertmanagerConfig` tells AlertManager how to route alerts from a specific namespace to specific receivers. It is namespace-scoped — a config in `logspam` only affects alerts from `PrometheusRule` resources in `logspam`.

📄 [5-alertmanager-config.yaml](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/alertmanager-webhook-alerts/5-alertmanager-config.yaml)

```bash
oc apply -f 5-alertmanager-config.yaml
```

```yaml
apiVersion: monitoring.coreos.com/v1beta1
kind: AlertmanagerConfig
metadata:
  name: logspam-alerts
  namespace: logspam
spec:
  route:
    groupBy:
    - alertname
    groupWait: 30s
    groupInterval: 1m
    repeatInterval: 5m
    receiver: webhook
  receivers:
  - name: webhook
    webhookConfigs:
    - url: "http://webhook-receiver.logspam.svc.cluster.local:8080"
      sendResolved: true
```

A few things worth understanding:

- **`groupBy: [alertname]`** groups alerts by their name. If five pods restart at the same time, you get one webhook call containing all five alerts rather than five separate calls. This prevents alert storms from overwhelming receivers.
- **`groupWait: 30s`** waits 30 seconds after a new alert group appears before sending the first notification. This lets AlertManager collect any additional alerts that fire in quick succession and batch them together.
- **`groupInterval: 1m`** is how often AlertManager sends updates for an existing group after the initial notification — if new alerts join the group, the update goes out within 1 minute.
- **`repeatInterval: 5m`** controls how often AlertManager re-sends a notification for an alert that is still firing with no changes. Set this low for the demo so you can see repeated deliveries; in production, 4 hours or longer is common.
- **`sendResolved: true`** sends a notification when an alert stops firing, so the receiver knows the issue has cleared.

Verify the config was accepted:

```bash
oc get alertmanagerconfig logspam-alerts -n logspam
```

```
NAME             AGE
logspam-alerts   5s
```

At this point, the `LogspamAlwaysFiring` alert is already firing from Step 4. AlertManager should route it to the webhook receiver within 30-60 seconds. Check the webhook logs:

```bash
oc logs -n logspam -l app=webhook-receiver -f
```

```
==================================================
  ALERT RECEIVED: 2026-07-13T14:30:42Z
==================================================
  Status:      firing
  Alert:       LogspamAlwaysFiring
  Severity:    info
  Summary:     Test alert - always firing
  Description: This alert always fires and is used to verify the alerting pipeline is working end-to-end.
--------------------------------------------------
==================================================
```

The pipeline is working. Alerts are flowing from PrometheusRule through AlertManager to the webhook receiver.

---

### Step 6: Trigger a Real Alert

The always-firing test alert proves the pipeline works, but it is more satisfying to see a real alert fire from a real event. The script sends `SIGUSR1` to the log-generator container, which triggers the `trap` handler from Step 2 and causes the container to exit with an error. Kubelet restarts the container within the same pod, incrementing the `kube_pod_container_status_restarts_total` counter — which is exactly what the `LogspamContainerRestarted` rule watches.

> Why not just delete the pod? Deleting a pod creates a brand new pod with a restart count of zero. The `kube_pod_container_status_restarts_total` metric only increments when kubelet restarts a container within an existing pod — a crash, not a replacement. Sending a signal crashes the container without destroying the pod, so kubelet restarts it and the counter goes up.

📄 [6-trigger-restart.sh](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/alertmanager-webhook-alerts/6-trigger-restart.sh)

```bash
bash 6-trigger-restart.sh
```

```
==> Sending SIGUSR1 to crash the log-generator container...
==> Waiting for the container to restart...
NAME                             READY   STATUS    RESTARTS      AGE
log-generator-7df88b749f-z9g5l   1/1     Running   1 (5s ago)   3m

==> The LogspamContainerRestarted alert should fire within ~3 minutes.
```

What happens next:

1. The `SIGUSR1` signal triggers the `trap` handler, the container exits with code 1
2. Kubelet restarts the container within the same pod — the `RESTARTS` column increments
3. Prometheus scrapes the updated `kube_pod_container_status_restarts_total` metric
4. The `increase(...[5m]) > 0` expression evaluates to true
5. After the 1-minute `for` duration, the alert transitions from `pending` to `firing`
6. AlertManager groups it and sends the payload to the webhook within 30 seconds

Watch both the alert status and the webhook logs:

```bash
oc logs -n logspam -l app=webhook-receiver -f
```

After a few minutes:

```
==================================================
  ALERT RECEIVED: 2026-07-13T14:38:15Z
==================================================
  Status:      firing
  Alert:       LogspamContainerRestarted
  Severity:    warning
  Summary:     Container restart detected in logspam namespace
  Description: Pod log-generator-7df88b749f-z9g5l in namespace logspam has restarted in the last 5 minutes.
--------------------------------------------------
==================================================
```

Once the 5-minute window passes and the restart count stabilizes, AlertManager sends a resolved notification (because `sendResolved: true` is set):

```
==================================================
  ALERT RECEIVED: 2026-07-13T14:44:22Z
==================================================
  Status:      resolved
  Alert:       LogspamContainerRestarted
  Severity:    warning
  Summary:     Container restart detected in logspam namespace
  Description: Pod log-generator-7df88b749f-z9g5l in namespace logspam has restarted in the last 5 minutes.
--------------------------------------------------
==================================================
```

That is the full alerting lifecycle: fire, deliver, resolve, confirm.

---

## Cleaning Up the Test Alert

Once you have verified the pipeline works, remove the always-firing test alert so it does not clutter your AlertManager. Edit `4-prometheus-rule.yaml` and delete the `LogspamAlwaysFiring` rule block, then reapply:

```bash
oc apply -f 4-prometheus-rule.yaml
```

The webhook receiver will log a `resolved` notification for `LogspamAlwaysFiring` shortly after.

---

## Routing Platform Alerts to a Receiver

Everything above covers **user-defined** alerts — PrometheusRule and AlertmanagerConfig resources that live in your namespace. But OpenShift also ships with hundreds of **platform alerts** out of the box: etcd latency, node pressure, API server errors, certificate expiry, cluster operator degraded, and more. These are pre-configured by the Cluster Monitoring Operator and fire automatically.

The catch: platform alerts have no receivers configured by default. They show up in the Observe console under **Observe > Alerting**, but they do not go anywhere externally until you tell them to.

Platform alert routing is configured differently from user-defined alerts. Instead of an `AlertmanagerConfig` CR (which is namespace-scoped to user workloads), platform alerts are routed through the **`alertmanager-main` Secret** in `openshift-monitoring`. This is the global AlertManager configuration and requires cluster-admin access.

To see the current configuration:

```bash
oc -n openshift-monitoring get secret alertmanager-main \
  -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d
```

The default output looks something like this — a single `null` receiver that discards everything:

```yaml
global:
  resolve_timeout: 5m
route:
  receiver: "null"
  group_by:
  - namespace
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 12h
receivers:
- name: "null"
```

To add a receiver, update the secret. For example, to route all critical platform alerts to a webhook:

```yaml
global:
  resolve_timeout: 5m
route:
  receiver: default
  group_by:
  - namespace
  - alertname
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 12h
  routes:
  - match:
      severity: critical
    receiver: ops-webhook
receivers:
- name: default
- name: ops-webhook
  webhook_configs:
  - url: "http://your-webhook-endpoint:8080"
    send_resolved: true
```

Apply the updated config by encoding and patching the secret:

```bash
oc -n openshift-monitoring create secret generic alertmanager-main \
  --from-file=alertmanager.yaml=alertmanager-config.yaml \
  --dry-run=client -o yaml | oc apply -f -
```

You can also configure this through the web console under **Administration > Cluster Settings > Configuration > Alertmanager**, which provides forms for the five Red Hat supported receiver types: Email, Slack, PagerDuty, Webhook, and Microsoft Teams.

Verify the configuration was applied:

```bash
oc -n openshift-monitoring get secret alertmanager-main \
  -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d
```

> **Platform vs. user-defined:** The `alertmanager-main` Secret handles platform alerts and is cluster-admin territory. The `AlertmanagerConfig` CR handles user-defined alerts and is namespace-scoped — developers can manage their own routing without admin help. Both feed into the same AlertManager pods in `openshift-monitoring`, but through different configuration paths.

---

## Where To Go From Here

The webhook receiver makes the alerting pipeline visible, but in production you would swap it for a real notification channel. The `AlertmanagerConfig` supports these receiver types for user-defined alerts:

| Receiver | Field in `spec.receivers` | Use case |
|---|---|---|
| Slack | `slackConfigs` | Team channels, ChatOps |
| PagerDuty | `pagerdutyConfigs` | On-call paging |
| Email | `emailConfigs` | Ticketing, audit trails |
| Webhook | `webhookConfigs` | Custom integrations, ServiceNow, generic HTTP |
| Microsoft Teams | `msTeamsConfigs` | Team notifications |

Each is a drop-in replacement in the `receivers` block — the route and PrometheusRule stay the same. These five receiver types are the ones Red Hat explicitly documents and supports. The upstream AlertManager CRD includes additional receiver types (Discord, OpsGenie, Jira, Telegram, SNS, and others), but they are not covered under Red Hat support. For any integration not in the list above, the webhook receiver type is the supported escape hatch — point it at a middleware or bridge service that translates to your target system.

For more context on the monitoring stack this builds on, the earlier posts in this series cover related ground:

- [Extending OpenShift Monitoring: Exporting Metrics and Building Custom Dashboards](/2026/04/01/extending-openshift-monitoring.html) — querying Thanos and deploying custom Grafana
- [Shipping OpenShift Logs to an External Syslog Server](/2026/04/03/forwarding-openshift-logs-syslog.html) — the `logspam` workload and log forwarding pipeline
- [Querying OpenShift Logs with LokiStack and Grafana](/2026/04/08/visualizing-openshift-logs-grafana.html) — log visualization alongside syslog forwarding

---

## References

- [OCP Docs: Configuring user workload monitoring](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/monitoring/configuring-user-workload-monitoring)
- [OCP Docs: Configuring alert notifications](https://docs.redhat.com/en/documentation/openshift_container_platform/4.17/html/monitoring/config-map-reference-for-the-cluster-monitoring-operator)
- [Red Hat Developer: How to configure OpenShift application monitoring and alerts](https://developers.redhat.com/articles/2023/10/03/how-configure-openshift-application-monitoring-and-alerts)
- [Red Hat Developer: OpenShift Monitoring and Webhook Alert Notifications](https://developers.redhat.com/blog/2025/03/03/openshift-monitoring-and-webhook-alert-notifications)
