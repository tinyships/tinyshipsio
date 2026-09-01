---
layout: post
title: "Sending SNMP Traps from OpenShift AlertManager"
date: 2026-07-19
---

OpenShift AlertManager supports webhooks, Slack, PagerDuty, and email natively — but not SNMP. If your operations team runs a network management system that speaks SNMP (Nagios, Zabbix, SolarWinds, HP OpenView), there is a gap between what AlertManager sends and what your NMS expects. This is a quick why and how-to for bridging that gap with a webhook-to-SNMP-trap translator, and deploying a trap receiver on the cluster so you can see the full pipeline working end-to-end.

## Why This Matters

SNMP has been the common language of network and infrastructure monitoring for decades. Every enterprise NMS, every DCIM platform, every mature operations center has SNMP trap ingestion as a core capability. When a router flaps or a PDU trips, it sends an SNMP trap. When a storage array degrades, it sends an SNMP trap. That is how operations teams have consumed infrastructure alerts for thirty years.

OpenShift runs alongside that infrastructure but speaks a different language. Its AlertManager can fire on etcd latency, node pressure, API server errors, certificate expiry, and custom application metrics — all high-value signals for an operations team. But those alerts stay in the Kubernetes ecosystem unless you explicitly route them outward. If your ops team monitors everything else through SNMP, having OpenShift alerts arrive through a completely separate channel means they get missed, or they require a second pane of glass that nobody watches consistently.

The bridge is a small component called **snmp_notifier**. AlertManager sends it a webhook, it translates the alert payload into an SNMP v2c or v3 trap, and it sends that trap to your NMS. From the NMS perspective, OpenShift alerts look exactly like any other infrastructure event — same protocol, same trap format, same escalation workflows.

---

## The Steps

1. Enable user-workload monitoring and alert routing on the cluster
2. Build and deploy an SNMP trap receiver (snmptrapd) for testing
3. Deploy the snmp_notifier webhook-to-SNMP-trap bridge
4. Create a test PrometheusRule and route it to snmp_notifier
5. Verify traps arrive at the trap receiver
6. Configure platform alerts to route through snmp_notifier

---

## How To Do It

### Step 1: Enable User-Workload Monitoring

User-workload monitoring is disabled by default. This ConfigMap enables it along with user-defined alert routing. If you already have this enabled from a previous setup, skip to Step 2.

📄 [1-enable-user-workload-monitoring.yaml](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/alertmanager-snmp-traps/1-enable-user-workload-monitoring.yaml)

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

`enableUserWorkload` deploys a dedicated Prometheus and Thanos Ruler for user namespaces. `enableUserAlertmanagerConfig` allows `AlertmanagerConfig` resources in user namespaces to route alerts to custom receivers. The [AlertManager Webhook Alerts post](/2026/07/13/alertmanager-webhook-alerts.html) covers both settings in more detail.

> If a `cluster-monitoring-config` ConfigMap already exists on your cluster, merge these keys into the existing `config.yaml` rather than replacing it.

Verify the user-workload monitoring pods are running:

```bash
oc get pods -n openshift-user-workload-monitoring
```

All pods should show `Running` within 60 seconds.

---

### Step 2: Build and Deploy the SNMP Trap Receiver

The trap receiver runs `snmptrapd` from the `net-snmp` package inside a UBI 9 image built in-cluster. It listens on **port 1162** instead of the standard 162 because 162 is a privileged port that requires root to bind — the container runs as non-root `UID 1001`.

📄 [2-snmptrapd.yaml](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/alertmanager-snmp-traps/2-snmptrapd.yaml)

```bash
oc apply -f 2-snmptrapd.yaml
```

This single file creates every resource needed: a namespace, the build pipeline, configuration, and the running trap receiver. Here is what each piece does.

#### Namespace

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: snmp-demo
```

All SNMP demo resources land in the `snmp-demo` namespace.

#### ImageStream and BuildConfig

```yaml
apiVersion: image.openshift.io/v1
kind: ImageStream
metadata:
  name: snmptrapd
  namespace: snmp-demo
---
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata:
  name: snmptrapd
  namespace: snmp-demo
spec:
  output:
    to:
      kind: ImageStreamTag
      name: snmptrapd:latest
  source:
    type: Dockerfile
    dockerfile: |
      FROM registry.access.redhat.com/ubi9/ubi:latest
      RUN dnf install -y net-snmp net-snmp-utils && dnf clean all && rm -rf /var/cache/dnf
      RUN mkdir -p /usr/share/snmp/mibs
      USER 1001
  strategy:
    type: Docker
    dockerStrategy: {}
  triggers:
  - type: ConfigChange
```

The `BuildConfig` installs `net-snmp` and `net-snmp-utils` into a UBI 9 base image at build time. `net-snmp` provides `snmptrapd` (the trap daemon), and `net-snmp-utils` provides `snmptrap` (a CLI tool for sending test traps). The `ConfigChange` trigger fires the build automatically when the resource is created.

Wait for the build to complete before the Deployment can start:

```bash
oc get builds -n snmp-demo -w
```

```
NAME          TYPE     FROM         STATUS     STARTED          DURATION
snmptrapd-1   Docker   Dockerfile   Complete   30 seconds ago   25s
```

#### ConfigMap: snmptrapd configuration

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: snmptrapd-config
  namespace: snmp-demo
data:
  snmptrapd.conf: |
    disableAuthorization yes
```

`disableAuthorization yes` tells snmptrapd to accept traps from any source without community string validation. This is appropriate for testing — in production you would configure specific community strings or SNMPv3 users.

#### ConfigMap: SNMP-NOTIFIER-MIB

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: snmp-notifier-mib
  namespace: snmp-demo
data:
  SNMP-NOTIFIER-MIB.my: |
    SNMP-NOTIFIER-MIB DEFINITIONS ::= BEGIN
    ...
    END
```

The MIB (Management Information Base) defines the structure of traps sent by snmp_notifier. Without it, snmptrapd displays raw OIDs like `1.3.6.1.4.1.98789.2.1`. With it loaded, those OIDs resolve to human-readable names like `snmpNotifierAlertId`, `snmpNotifierAlertSeverity`, and `snmpNotifierAlertDescription`. The MIB is published in the [snmp_notifier GitHub repository](https://github.com/maxwo/snmp_notifier/tree/master/mibs) and mounted into snmptrapd at `/etc/snmp/mibs`.

#### ConfigMap: startup script

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: snmptrapd-startup
  namespace: snmp-demo
data:
  start.sh: |
    #!/bin/bash
    set -e
    echo "snmptrapd starting, listening on UDP 1162..."
    exec snmptrapd -f -Lo -m ALL -M +/etc/snmp/mibs 1162
```

The startup script runs snmptrapd in the foreground (`-f`) logging to stdout (`-Lo`) so trap output appears in `oc logs`. `-m ALL` loads all available MIBs and `-M /etc/snmp/mibs` adds the mounted MIB directory to the search path. The trailing `1162` is the listen port.

#### Deployment and Service

The Deployment pulls the built image from the internal registry, mounts all three ConfigMaps, and exposes port 1162 UDP. The Service gives snmp_notifier a stable DNS name to target: `snmptrapd.snmp-demo.svc.cluster.local:1162`.

Verify the pod is running:

```bash
oc get pods -n snmp-demo -l app=snmptrapd
```

```
NAME                        READY   STATUS    RESTARTS   AGE
snmptrapd-6b8f9d7c4-xk2pj  1/1     Running   0          15s
```

Test that snmptrapd is receiving by sending a manual trap from within the pod:

```bash
oc exec -n snmp-demo deploy/snmptrapd -- \
  snmptrap -v 2c -c public localhost:1162 "" \
  1.3.6.1.4.1.98789.1 \
  1.3.6.1.4.1.98789.2.1 s "test-alert-id" \
  1.3.6.1.4.1.98789.2.2 s "info" \
  1.3.6.1.4.1.98789.2.3 s "Manual test trap from CLI"
```

Check the logs:

```bash
oc logs -n snmp-demo -l app=snmptrapd --tail=5
```

You should see the trap with the MIB-decoded field names:

```
snmptrapd starting, listening on UDP 1162...
DISMAN-EVENT-MIB::sysUpTimeInstance = Timeticks: (0) 0:00:00.00
SNMPv2-MIB::snmpTrapOID.0 = OID: SNMP-NOTIFIER-MIB::snmpNotifierDefaultTrap
SNMP-NOTIFIER-MIB::snmpNotifierAlertId = STRING: "test-alert-id"
SNMP-NOTIFIER-MIB::snmpNotifierAlertSeverity = STRING: "info"
SNMP-NOTIFIER-MIB::snmpNotifierAlertDescription = STRING: "Manual test trap from CLI"
```

The trap receiver is working and decoding OIDs to names.

---

### Step 3: Deploy the SNMP Notifier

The [snmp_notifier](https://github.com/maxwo/snmp_notifier) is an open-source webhook-to-SNMP-trap bridge. AlertManager sends it a webhook POST at `/alerts`, it extracts the alert labels and annotations, and it sends an SNMP v2c (or v3) trap to the configured destination. Each alert gets a unique trap with the alert name, severity, and a rendered description as varbind values.

📄 [3-snmp-notifier.yaml](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/alertmanager-snmp-traps/3-snmp-notifier.yaml)

```bash
oc apply -f 3-snmp-notifier.yaml
```

#### Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: snmp-notifier
  namespace: snmp-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: snmp-notifier
  template:
    metadata:
      labels:
        app: snmp-notifier
    spec:
      containers:
      - name: snmp-notifier
        image: docker.io/maxwo/snmp-notifier:v2.1.0
        args:
        - --trap.description-template=/etc/snmp_notifier/description-template.tpl
        - --snmp.destination=snmptrapd.snmp-demo.svc.cluster.local:1162
        - --snmp.version=V2c
        - --snmp.community=public
        - --alert.default-severity=critical
        - --alert.severities=critical,warning,info
        ports:
        - containerPort: 9464
          name: http
          protocol: TCP
```

A few things worth understanding:

- **`--trap.description-template`** tells snmp_notifier where to find the Go template used to render the trap description varbind. The image ships this file at `/etc/snmp_notifier/description-template.tpl`, but since Kubernetes `args` overrides the Docker CMD (which normally supplies this flag), it must be included explicitly.
- **`--snmp.destination`** points at the snmptrapd service deployed in Step 2. In production, this would be your NMS trap receiver (e.g., `nagios.corp.example.com:162`).
- **`--snmp.version=V2c`** uses SNMP version 2c with community string authentication. For production environments that require encryption and user-based auth, use `V3` with `--snmp.authentication-enabled`, `--snmp.authentication-protocol`, and `--snmp.private-protocol`.
- **`--snmp.community=public`** is the default v2c community string. Match it to whatever your NMS expects.
- **`--alert.severities=critical,warning,info`** defines the severity hierarchy. The trap description template groups alerts by severity in this order.

The snmp_notifier uses the enterprise OID `1.3.6.1.4.1.98789` (private enterprise number 98789) and sends traps with three varbinds: alert ID, severity, and a rendered description that includes the alert name, summary, and description annotations.

#### Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: snmp-notifier
  namespace: snmp-demo
spec:
  selector:
    app: snmp-notifier
  ports:
  - name: http
    port: 9464
    protocol: TCP
    targetPort: 9464
```

The Service provides the webhook URL that AlertManager targets: `http://snmp-notifier.snmp-demo.svc.cluster.local:9464/alerts`.

Verify the pod is running:

```bash
oc get pods -n snmp-demo -l app=snmp-notifier
```

```
NAME                             READY   STATUS    RESTARTS   AGE
snmp-notifier-5f8b7c9d4-m2xkj   1/1     Running   0          10s
```

---

### Step 4: Create Test Alerts and Route to SNMP

Now wire the pipeline together: a `PrometheusRule` defines the alerts, and an `AlertmanagerConfig` routes them to the snmp_notifier webhook.

📄 [4-prometheus-rule.yaml](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/alertmanager-snmp-traps/4-prometheus-rule.yaml)

```bash
oc apply -f 4-prometheus-rule.yaml
```

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: snmp-test-alerts
  namespace: snmp-demo
spec:
  groups:
  - name: snmp-demo.rules
    rules:
    - alert: SNMPTestAlwaysFiring
      expr: vector(1)
      for: 1m
      labels:
        severity: info
      annotations:
        summary: "SNMP test alert - always firing"
        description: "This alert always fires and is used to verify the SNMP trap pipeline is working end-to-end."
    - alert: SNMPTestHighSeverity
      expr: vector(1)
      for: 1m
      labels:
        severity: critical
      annotations:
        summary: "SNMP critical test alert"
        description: "A critical severity test alert to verify severity mapping in SNMP traps."
```

Two test alerts: one `info` and one `critical`. Both use `vector(1)` so they fire immediately after the 1-minute `for` duration. This lets you verify the full pipeline without waiting for a real event, and it confirms that severity levels map correctly into the SNMP trap varbinds.

📄 [5-alertmanager-config.yaml](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/alertmanager-snmp-traps/5-alertmanager-config.yaml)

```bash
oc apply -f 5-alertmanager-config.yaml
```

```yaml
apiVersion: monitoring.coreos.com/v1beta1
kind: AlertmanagerConfig
metadata:
  name: snmp-alerts
  namespace: snmp-demo
spec:
  route:
    groupBy:
    - alertname
    groupWait: 30s
    groupInterval: 1m
    repeatInterval: 5m
    receiver: snmp
  receivers:
  - name: snmp
    webhookConfigs:
    - url: "http://snmp-notifier.snmp-demo.svc.cluster.local:9464/alerts"
      sendResolved: true
```

The `AlertmanagerConfig` routes all alerts from the `snmp-demo` namespace to the snmp_notifier webhook. From AlertManager's perspective, this is a standard webhook receiver — AlertManager does not know or care that the webhook translates to SNMP on the other side.

Verify both resources exist:

```bash
oc get prometheusrule,alertmanagerconfig -n snmp-demo
```

```
NAME                                                      AGE
prometheusrule.monitoring.coreos.com/snmp-test-alerts      5s

NAME                                                       AGE
alertmanagerconfig.monitoring.coreos.com/snmp-alerts        5s
```

---

### Step 5: Verify SNMP Traps

The `vector(1)` alerts should transition to `firing` within 2 minutes. Once AlertManager routes them to the snmp_notifier webhook, traps should appear in the snmptrapd logs within 30 seconds after that.

Watch the trap receiver:

```bash
oc logs -n snmp-demo -l app=snmptrapd -f
```

After a few minutes you will see traps arriving with decoded MIB names:

```
DISMAN-EVENT-MIB::sysUpTimeInstance = Timeticks: (0) 0:00:00.00
SNMPv2-MIB::snmpTrapOID.0 = OID: SNMP-NOTIFIER-MIB::snmpNotifierDefaultTrap
SNMP-NOTIFIER-MIB::snmpNotifierAlertId = STRING: "SNMPTestAlwaysFiring[alertname=SNMPTestAlwaysFiring]"
SNMP-NOTIFIER-MIB::snmpNotifierAlertSeverity = STRING: "info"
SNMP-NOTIFIER-MIB::snmpNotifierAlertDescription = STRING: "2/2 alerts are firing:

Status: critical
- Alert: SNMPTestHighSeverity
  Summary: SNMP critical test alert
  Description: A critical severity test alert to verify severity mapping in SNMP traps.

Status: info
- Alert: SNMPTestAlwaysFiring
  Summary: SNMP test alert - always firing
  Description: This alert always fires and is used to verify the SNMP trap pipeline is working end-to-end.
"
```

The trap description groups alerts by severity and includes the alert name, summary, and description annotations — all rendered by snmp_notifier's built-in Go template. Your NMS receives this as a standard SNMPv2c trap with enterprise OID `1.3.6.1.4.1.98789.1` and three varbinds.

You can also check the alert states directly:

```bash
TOKEN=$(oc whoami -t)
THANOS_HOST=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')
curl -sk -H "Authorization: Bearer $TOKEN" \
  "https://$THANOS_HOST/api/v1/rules" | \
  python3 -c "
import sys, json
data = json.load(sys.stdin)
for group in data.get('data', {}).get('groups', []):
    if group.get('name') == 'snmp-demo.rules':
        for rule in group.get('rules', []):
            print(f\"  {rule['name']}: {rule['state']}\")
"
```

```
  SNMPTestAlwaysFiring: firing
  SNMPTestHighSeverity: firing
```

That is the user-defined alert pipeline working end-to-end: PrometheusRule fires, AlertManager routes to snmp_notifier webhook, snmp_notifier translates to SNMP trap, snmptrapd receives and decodes it.

---

### Step 6: Route Platform Alerts to SNMP

The steps above handle user-defined alerts in the `snmp-demo` namespace. Platform alerts — the pre-configured rules for etcd, node pressure, API server errors, and certificate expiry — use a different configuration path. They are routed through the `alertmanager-main` Secret in `openshift-monitoring`, not through `AlertmanagerConfig` resources.

📄 [6-platform-alerts.sh](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/alertmanager-snmp-traps/6-platform-alerts.sh)

The script reads the current AlertManager config, replaces it with a version that routes `critical` and `warning` platform alerts to snmp_notifier, and applies it.

```bash
bash 6-platform-alerts.sh
```

```
==> Reading current AlertManager configuration...
==> Applying new AlertManager configuration with SNMP receivers...
secret/alertmanager-main configured

==> Done. Platform alerts with severity critical or warning will now route to snmp-notifier.
    Watch the snmptrapd logs: oc logs -n snmp-demo -l app=snmptrapd -f
```

The new configuration adds two receivers that both point at the same snmp_notifier webhook, matched by severity:

```yaml
routes:
- match:
    severity: critical
  receiver: snmp-critical
- match:
    severity: warning
  receiver: snmp-warning
receivers:
- name: snmp-critical
  webhook_configs:
  - url: "http://snmp-notifier.snmp-demo.svc.cluster.local:9464/alerts"
    send_resolved: true
- name: snmp-warning
  webhook_configs:
  - url: "http://snmp-notifier.snmp-demo.svc.cluster.local:9464/alerts"
    send_resolved: true
```

If any platform alerts are currently firing, they will appear as SNMP traps in the snmptrapd logs within a few minutes. You can check for firing platform alerts with:

```bash
oc get alerts -A 2>/dev/null || \
  curl -sk -H "Authorization: Bearer $(oc whoami -t)" \
  "https://$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')/api/v1/alerts" | \
  python3 -c "
import sys, json
data = json.load(sys.stdin)
for alert in data.get('data', {}).get('alerts', [])[:10]:
    name = alert.get('labels', {}).get('alertname', '')
    sev = alert.get('labels', {}).get('severity', '')
    state = alert.get('state', '')
    if state == 'firing':
        print(f'  {name} [{sev}]: {state}')
"
```

> **Restoring the default:** To remove SNMP routing from platform alerts, restore the original `alertmanager-main` Secret. The simplest way is to delete the secret — the Cluster Monitoring Operator recreates it with the default configuration within a few seconds:
>
> ```bash
> oc -n openshift-monitoring delete secret alertmanager-main
> ```

---

## Production Considerations

This demo uses SNMP v2c with a `public` community string, which is fine for testing but not for production. Here is what to change:

**SNMP v3 with authentication and encryption:**

```yaml
args:
- --snmp.destination=nms.corp.example.com:162
- --snmp.version=V3
- --snmp.authentication-enabled
- --snmp.authentication-protocol=SHA
- --snmp.authentication-username=openshift-alerts
- --snmp.private-enabled
- --snmp.private-protocol=AES
env:
- name: SNMP_NOTIFIER_AUTH_PASSWORD
  valueFrom:
    secretKeyRef:
      name: snmp-credentials
      key: auth-password
- name: SNMP_NOTIFIER_PRIV_PASSWORD
  valueFrom:
    secretKeyRef:
      name: snmp-credentials
      key: priv-password
```

**Custom trap OIDs:** If your NMS expects a specific enterprise OID, use `--trap.default-oid` to override the default `1.3.6.1.4.1.98789.1`. You can also set per-alert OIDs by adding an `oid` label to your PrometheusRule alerts.

**High availability:** Run multiple snmp_notifier replicas behind the same Service. AlertManager's webhook retries handle transient failures, and snmp_notifier is stateless.

---

## Where To Go From Here

- [Alerting on OpenShift Workloads with AlertManager and a Webhook Receiver](/2026/07/13/alertmanager-webhook-alerts.html) — the foundational post on user-workload monitoring, PrometheusRule, and AlertmanagerConfig
- [Extending OpenShift Monitoring: Exporting Metrics and Building Custom Dashboards](/2026/04/01/extending-openshift-monitoring.html) — querying Thanos and deploying custom Grafana

---

## References

- [snmp_notifier GitHub repository](https://github.com/maxwo/snmp_notifier)
- [OCP Docs: Configuring user workload monitoring](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/monitoring/configuring-user-workload-monitoring)
- [OCP Docs: Configuring alert notifications](https://docs.redhat.com/en/documentation/openshift_container_platform/4.17/html/monitoring/config-map-reference-for-the-cluster-monitoring-operator)
