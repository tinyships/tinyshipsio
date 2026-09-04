---
layout: post
title: "Shipping OpenShift Logs to an External Syslog Server"
date: 2026-04-03
---

OpenShift ships with a full logging stack — collect, store, and view logs all within the cluster using the Logging Operator and LokiStack. That's a great starting point. But at some point you need logs to outlive the cluster, land in a centralized system that aggregates across environments, or feed into compliance and audit tooling that expects syslog. This is a quick why and how-to for configuring the OpenShift Logging Operator to forward logs to an external syslog server.

## Why This Matters

Most teams don't think hard about log routing until something breaks or audit season arrives. The default LokiStack setup stores logs inside the cluster, which is excellent for day-to-day debugging — but logs that live and die with the cluster aren't much use after a node failure, a cluster rebuild, or a security incident you're investigating three weeks later.

Syslog has been the lingua franca of centralized log aggregation for decades. Every SIEM, every compliance platform, every mature log management system speaks it. When you configure OpenShift to forward to syslog, you're plugging into that ecosystem without changing how your applications write logs. Your workloads log to stdout, the platform handles the rest.

The other thing worth slowing down to consider: the `ClusterLogForwarder` can send to multiple outputs simultaneously. You don't lose your local LokiStack — you add syslog alongside it. Set the routing once, and the platform fans it out.

---

## The Steps

1. Create a `logspam` namespace and deploy a `log-generator` Deployment running a UBI 9 container that emits log messages at random levels and intervals
2. Build and deploy an rsyslog server in its own namespace, exposed externally via NodePort
3. Install the OpenShift Logging Operator from OperatorHub
4. Create a `ClusterLogForwarder` pointing at the syslog external endpoint
5. **Bonus:** Install Loki and Grafana, then replace the Step 4 CLF with a dual-output version that sends logs to both syslog and LokiStack simultaneously

---

## How To Do It

### Step 1: The Log Generator

The log generator is a UBI 9 container running a shell loop that emits messages at all four log levels — INFO, WARN, ERROR, and DEBUG — at random intervals. It gives you real, varied log output to forward and inspect.

📄 [1-logspam.yaml](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/forwarding-openshift-logs-syslog/1-logspam.yaml)

```bash
oc apply -f 1-logspam.yaml
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

Verify the pod is running before tailing logs:

```bash
oc get pods -n logspam -l app=log-generator
```

```
NAME                             READY   STATUS    RESTARTS   AGE
log-generator-7d6f9b8c4-xk2pj   1/1     Running   0          30s
```

Then follow the output:

```bash
oc logs -n logspam -l app=log-generator -f
```

```
[INFO] Application started successfully at 2026-04-01T10:23:41Z
[ERROR] Failed to connect to database - retrying at 2026-04-01T10:23:44Z
[WARN] High memory usage detected: 85% at 2026-04-01T10:23:46Z
```

---

### Step 2: The Syslog Server

The syslog server runs rsyslog inside a UBI 9 image built in-cluster. Building rsyslog into the image at build time — rather than installing it at runtime — means the container runs as a non-root user (`UID 1001`) with no elevated privileges needed. Port 514 is a privileged port that requires root to bind, so the server listens on **port 1514** instead, which any non-root process can bind freely.

📄 [2-syslog-server.yaml](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/forwarding-openshift-logs-syslog/2-syslog-server.yaml)

This single file creates every resource needed to build and run the syslog server — from the namespace through to the services. Here's what's in it and why each piece exists.

```bash
oc apply -f 2-syslog-server.yaml
```

#### Namespace

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: syslog-server
```

All syslog server resources land in the `syslog-server` namespace, keeping them isolated from the log generator and the logging operator.

#### ImageStream

```yaml
apiVersion: image.openshift.io/v1
kind: ImageStream
metadata:
  name: rsyslog-server
  namespace: syslog-server
```

An `ImageStream` is OpenShift's internal image reference. The `BuildConfig` pushes the built image to this stream, and the `Deployment` pulls from it. This keeps everything inside the cluster's internal registry — no external image pull needed.

#### BuildConfig

```yaml
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata:
  name: rsyslog-server
  namespace: syslog-server
spec:
  output:
    to:
      kind: ImageStreamTag
      name: rsyslog-server:latest
  source:
    type: Dockerfile
    dockerfile: |
      FROM registry.access.redhat.com/ubi9/ubi:latest
      RUN dnf install -y rsyslog && dnf clean all && rm -rf /var/cache/dnf
      USER 1001
  strategy:
    type: Docker
    dockerStrategy: {}
  triggers:
  - type: ConfigChange
```

The `BuildConfig` installs rsyslog into a UBI 9 base image at build time and drops to `UID 1001` before the image is committed. The `ConfigChange` trigger fires the build automatically when the `BuildConfig` is first created. The result is pushed to the `rsyslog-server` ImageStream.

Wait for the build to complete before the Deployment pod can start (about 60 seconds):

```bash
oc get builds -n syslog-server -w
```

#### ConfigMap: rsyslog config

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: rsyslog-config
  namespace: syslog-server
data:
  rsyslog.conf: |
    global(workDirectory="/tmp/rsyslog")

    module(load="imudp")
    input(type="imudp" port="1514")

    module(load="imtcp")
    input(type="imtcp" port="1514")

    $template RemoteFormat,"%TIMESTAMP:::date-rfc3339% [%HOSTNAME%] %syslogtag%%msg%\n"
    *.* /tmp/syslog/syslog.log;RemoteFormat
```

The rsyslog configuration is mounted into the container at `/etc/rsyslog-custom/rsyslog.conf`. All paths are under `/tmp` — writable by any user — since the container runs without root. The server accepts both TCP and UDP on 1514 and writes every received message to `/tmp/syslog/syslog.log` using a timestamp-prefixed format.

#### ConfigMap: startup script

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: rsyslog-startup
  namespace: syslog-server
data:
  start.sh: |
    #!/bin/bash
    set -e
    mkdir -p /tmp/rsyslog /tmp/syslog
    touch /tmp/syslog/syslog.log
    rsyslogd -n -i /tmp/rsyslog/rsyslogd.pid -f /etc/rsyslog-custom/rsyslog.conf &
    echo "rsyslog started, listening on TCP/UDP 1514"
    exec tail -f /tmp/syslog/syslog.log
```

The startup script is mounted at `/startup/start.sh` and runs as the container's entrypoint. It creates the working directories, starts rsyslogd in the background with the custom config, then execs `tail -f` on the log file so the container's stdout streams received syslog messages — making them visible via `oc logs`.

#### Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rsyslog-server
  namespace: syslog-server
spec:
  replicas: 1
  selector:
    matchLabels:
      app: rsyslog-server
  template:
    metadata:
      labels:
        app: rsyslog-server
    spec:
      containers:
      - name: rsyslog
        image: image-registry.openshift-image-registry.svc:5000/syslog-server/rsyslog-server:latest
        command: ["/bin/bash", "/startup/start.sh"]
        ports:
        - name: syslog-tcp
          containerPort: 1514
          protocol: TCP
        - name: syslog-udp
          containerPort: 1514
          protocol: UDP
        volumeMounts:
        - name: startup
          mountPath: /startup
        - name: rsyslog-config
          mountPath: /etc/rsyslog-custom
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
          limits:
            cpu: "200m"
            memory: "256Mi"
      volumes:
      - name: startup
        configMap:
          name: rsyslog-startup
          defaultMode: 0755
      - name: rsyslog-config
        configMap:
          name: rsyslog-config
```

The Deployment pulls the image from the internal registry, mounts both ConfigMaps, and exposes port 1514 on both TCP and UDP. The `defaultMode: 0755` on the startup ConfigMap volume ensures the script is executable when mounted.

#### Services

OpenShift Routes are HTTP/HTTPS only — they use HAProxy at layer 7 and can't pass raw TCP syslog traffic. To reach the syslog server you need a `Service` instead. The YAML creates two:

```yaml
# In-cluster access — used by the CLF when forwarding within the same cluster
apiVersion: v1
kind: Service
metadata:
  name: rsyslog-service
  namespace: syslog-server
spec:
  selector:
    app: rsyslog-server
  ports:
  - name: syslog-tcp
    port: 1514
    protocol: TCP
    targetPort: 1514
  - name: syslog-udp
    port: 1514
    protocol: UDP
    targetPort: 1514
---
# External access — fixed NodePort 31514
apiVersion: v1
kind: Service
metadata:
  name: rsyslog-external
  namespace: syslog-server
spec:
  type: NodePort
  selector:
    app: rsyslog-server
  ports:
  - name: syslog-tcp
    port: 1514
    protocol: TCP
    targetPort: 1514
    nodePort: 31514
```

The `ClusterIP` service (`rsyslog-service`) is what the `ClusterLogForwarder` uses when forwarding logs within the same cluster — reachable at `rsyslog-service.syslog-server.svc.cluster.local:1514`. The `NodePort` service (`rsyslog-external`) exposes the server on port 31514 of any worker node for external access. A fixed `nodePort: 31514` makes it predictable — you know the port without having to look it up.

> For production, prefer `type: LoadBalancer` on cloud platforms — it provisions an external load balancer with a stable IP rather than relying on individual node IPs. NodePort works well for on-premises and demo environments.

---

### Step 3: Install the OpenShift Logging Operator

The Logging Operator is a Red Hat supported operator available from OperatorHub. As of Logging 6.x, it manages a Vector collector DaemonSet automatically when a `ClusterLogForwarder` is created — no separate `ClusterLogging` instance required.

If you're new to how operators work — what OLM is doing, how channels and subscriptions relate, or how to explore what an operator registers — the post [How to Find, Install, and Explore an OpenShift Operator from the CLI](/2026/04/06/exploring-openshift-operators.html) covers all of that in detail.

📄 [3-install-logging-operator.yaml](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/forwarding-openshift-logs-syslog/3-install-logging-operator.yaml)

This file creates three resources that OLM needs to install an operator from the CLI:

```bash
oc apply -f 3-install-logging-operator.yaml
```

#### Namespace

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-logging
  annotations:
    openshift.io/node-selector: ""
  labels:
    openshift.io/cluster-monitoring: "true"
```

The `openshift-logging` namespace is where the operator and all logging resources live. The `openshift.io/node-selector: ""` annotation clears any default node selector so the operator pods aren't accidentally restricted to a subset of nodes. The `openshift.io/cluster-monitoring: "true"` label opts the namespace into cluster monitoring so the operator's metrics are scraped automatically.

#### OperatorGroup

```yaml
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-logging
  namespace: openshift-logging
spec:
  targetNamespaces:
  - openshift-logging
```

The `OperatorGroup` tells OLM which namespaces this operator is allowed to watch. Without one in the namespace, the Subscription will stall indefinitely. Scoping `targetNamespaces` to `openshift-logging` only gives the operator access to that namespace rather than cluster-wide.

#### Subscription

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-logging
  namespace: openshift-logging
spec:
  channel: stable-6.5
  installPlanApproval: Automatic
  name: cluster-logging
  source: redhat-operators
  sourceNamespace: openshift-marketplace
```

The `Subscription` is what triggers OLM to pull and install the operator. It references the `redhat-operators` catalog, the `cluster-logging` package, and a specific channel. The Logging Operator does not publish a generic `stable` channel — check which channels are available on your cluster before applying:

```bash
oc get packagemanifest cluster-logging -o jsonpath='{.status.channels[*].name}'
```

`installPlanApproval: Automatic` means OLM approves and executes the install without manual intervention. Use `Manual` in production if you want to inspect the `InstallPlan` before committing to an upgrade.

Wait for the operator CSV to reach `Succeeded` before moving on — a running pod is not sufficient confirmation:

```bash
oc get csv -n openshift-logging -w
```

```
NAME                       DISPLAY                     VERSION   PHASE
cluster-logging.v6.5.0     Red Hat OpenShift Logging   6.5.0     Installing
cluster-logging.v6.5.0     Red Hat OpenShift Logging   6.5.0     Succeeded
```

---

### Step 4: Configure Log Forwarding

Logging 6.x introduced a new API group — `observability.openshift.io/v1` — and dropped the `ClusterLogging` resource entirely. The `ClusterLogForwarder` now owns the full configuration: what to collect, where to send it, and which service account the collector runs as.

📄 [4-cluster-log-forwarder.yaml](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/forwarding-openshift-logs-syslog/4-cluster-log-forwarder.yaml)

This file creates three resources: a `ServiceAccount` for the collector, a `ClusterRoleBinding` that grants it read access to application logs, and the `ClusterLogForwarder` itself.

```bash
oc apply -f 4-cluster-log-forwarder.yaml
```

#### ServiceAccount

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: logcollector
  namespace: openshift-logging
```

The Vector collector DaemonSet runs as this ServiceAccount. Logging 6.x requires an explicit `serviceAccount` reference in the `ClusterLogForwarder` — the operator will not deploy the collector without it.

#### ClusterRoleBinding

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: logging-collector-application-logs
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: collect-application-logs
subjects:
- kind: ServiceAccount
  name: logcollector
  namespace: openshift-logging
```

The `collect-application-logs` ClusterRole is installed by the Logging Operator and grants the collector read access to application pod logs across all namespaces. Without this binding the collector starts but cannot read any logs.

#### ClusterLogForwarder

```yaml
apiVersion: observability.openshift.io/v1
kind: ClusterLogForwarder
metadata:
  name: instance
  namespace: openshift-logging
spec:
  serviceAccount:
    name: logcollector

  inputs:
  - name: logspam-logs
    type: application
    application:
      includes:
      - namespace: logspam

  outputs:
  - name: syslog-out
    type: syslog
    syslog:
      url: tcp://rsyslog-service.syslog-server.svc.cluster.local:1514
      rfc: RFC5424
      facility: user
      enrichment: KubernetesMinimal

  pipelines:
  - name: app-to-syslog
    inputRefs:
    - logspam-logs
    outputRefs:
    - syslog-out
```

A few things worth understanding:

- **`inputs`** with `application.includes` scopes collection to the `logspam` namespace only. Remove this block and use the built-in `application` input ref to collect from all application namespaces.
- **`rfc: RFC5424`** is the structured syslog format — facility, severity, hostname, and app name as defined fields, useful if your downstream system parses structured data.
- **`enrichment: KubernetesMinimal`** attaches a reduced set of Kubernetes metadata to each log event — namespace, pod name, and container name only. The default includes the full pod annotations and labels, which can push individual syslog messages to several kilobytes. `KubernetesMinimal` keeps messages manageable without losing the context you need for troubleshooting.
- **`url`** uses the internal service created in Step 2 since the CLF and the syslog server are on the same cluster.

#### Verify the Pipeline

Give the operator a moment to deploy the Vector DaemonSet, then confirm the CLF is ready:

```bash
oc get clusterlogforwarder instance -n openshift-logging -o jsonpath='{.status.conditions}' | jq .
```

Then watch the syslog server receive logs:

```bash
oc logs -n syslog-server -l app=rsyslog-server -f
```

You'll see RFC5424 entries arriving from the `logspam` pod with minimal Kubernetes metadata:

```
2026-04-01T20:08:00Z [control-plane] logspam_log-generator_log-generator {...,"message":"[INFO] Application started successfully","level":"info","kubernetes":{"namespace_name":"logspam","pod_name":"log-generator-...","container_name":"log-generator"}}
```

That's the forwarding pipeline working end-to-end.

#### Optional: Switch to the NodePort for External Access

If you want to simulate forwarding to a truly external syslog destination — or verify the NodePort is reachable from outside the cluster — the helper script patches the CLF URL to use the worker node IP and NodePort instead:

📄 [5-get-external-url.sh](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/forwarding-openshift-logs-syslog/5-get-external-url.sh)

```bash
bash 5-get-external-url.sh
```

```
External syslog URL: tcp://10.0.1.42:31514
Patching ClusterLogForwarder...
clusterlogforwarder.observability.openshift.io/instance patched
```

The script reads the IP of a worker node, constructs the full `tcp://<node-ip>:31514` URL, and patches the `syslog-out` output in place. In a real deployment this is where you'd substitute your centralized syslog server's hostname and port — Splunk, Graylog, a managed SIEM — and nothing else in this setup changes.

---

That's the forwarding pipeline complete. Logs leave your cluster, arrive at a syslog server you control, and the only thing connecting them is a `ClusterLogForwarder` and a service endpoint. In a real deployment, swap the internal service URL for your centralized syslog server — Splunk, Graylog, a managed SIEM — and nothing else changes.

If you want to go further and query those same logs interactively inside the cluster, the next post covers adding LokiStack and Grafana to the same setup: [Querying OpenShift Logs with LokiStack and Grafana](/2026/04/08/visualizing-openshift-logs-grafana.html).

---

## References

- [OCP Logging 6.5 Docs: Configuring log forwarding](https://docs.redhat.com/en/documentation/red_hat_openshift_logging/6.5/html/configuring_logging/configuring-log-forwarding)
- [OCP Logging 6.5 Docs: Installing logging](https://docs.redhat.com/en/documentation/red_hat_openshift_logging/6.5/html-single/installing_logging/index)
