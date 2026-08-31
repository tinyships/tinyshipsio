---
layout: post
title: "Scaling OpenShift Monitoring: Feeding Cluster Metrics to an External Stack"
date: 2026-08-27
---

OpenShift ships with a production-grade monitoring stack, but it is designed for the platform team operating the cluster; not for a separate team that needs to watch not just OpenShift but a number of system types with their own tools. This is a quick why and how-to for two approaches to getting OpenShift metrics into an external Grafana instance that another team owns and operates: querying the cluster directly, and pushing metrics out via Prometheus remote-write. For this post we will use the Network Operations Center (NOC) team as the example.

## Why This Matters

Most organizations draw a clear line between the infrastructure team that runs OpenShift and the NOC team that monitors everything in production. Meaning they need to see cluster health alongside network gear, databases, and everything else they are responsible for.

That organizational split creates a technical problem. The cluster monitoring stack is not designed to serve an external consumer. Thanos Querier exposes metrics through a route, and you can absolutely point an external Grafana at it. That is approach one, and it works well for getting started, but it means every dashboard refresh in the NOC hits the cluster. If the NOC has ten analysts running dashboards across three clusters, that is continuous load on the OpenShift. More importantly, if a cluster goes unhealthy they potentially lose the ability to see what led up to the issue.

That is why approach two exists. Prometheus remote-write pushes metrics from the cluster to the NOC as they are generated. The NOC's own Prometheus stores them and their Grafana instance queries their Prometheus, not your OpenShift cluster. Now if a cluster goes down, the NOC still has every metric that was pushed before the outage, and the dashboards keep working for everything else.

Neither approach is universally better. Direct query is simpler and gives access to the full metric set with zero lag. Remote-write is more resilient and scales better across multiple clusters. The right choice depends on what the team needing the data needs to survive.

---

## The Steps

**Approach 1 — Point the NOC Grafana at the Cluster Thanos Querier**

1. Create a service account and bearer token on the cluster
2. Get the external Thanos Querier route URL
3. Add a Prometheus datasource in the NOC Grafana with the route URL and token

**Approach 2 — Push Metrics from the Cluster to the NOC Prometheus**

1. Build an example NOC Prometheus
2. Build an example NOC Grafana
3. Configure OpenShift to remote-write metrics to the example NOC Prometheus
4. Filter metrics to control what gets shipped to the example NOC Prometheus
5. Build NOC dashboards in the example NOC Grafana

---

## How To Do It

### Approach 1: Directly Querying the OpenShift cluster from the NOC Grafana

This approach utilizes the NOC's existing Grafana instance to query the OpenShift clusters Thanos Querier route using just a datasource configuration in Grafana.

The full setup for creating the service account, token, and Thanos connection is covered in [Extending OpenShift Monitoring: Exporting Metrics and Building Custom Dashboards](/2026/04/01/extending-openshift-monitoring/). That post deploys Grafana inside the cluster, but the service account and token setup (Steps 1 and 2) are identical for an external Grafana.

The key difference is the datasource URL. The in-cluster Grafana uses the internal service address:

```
https://thanos-querier.openshift-monitoring.svc.cluster.local:9091
```

The NOC's external Grafana uses the external route instead. Get it with:

```bash
oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}'
```

Then extract the bearer token from the service account secret:

```bash
oc get secret custom-grafana-token -n my-custom-metrics -o jsonpath='{.data.token}' | base64 -d
```

In the NOC's Grafana, add a new Prometheus datasource with these settings:

| Setting | Value |
|---|---|
| **URL** | `https://<thanos-route-from-above>` |
| **Access** | Server |
| **Skip TLS Verify** | Enabled (or provide the cluster CA) |
| **Custom HTTP Header** | `Authorization` |
| **Header Value** | `Bearer <token-from-above>` |

Save and test the datasource. If it connects, the NOC Grafana now has access to every metric the cluster Prometheus collects.

**Verify the connection:**

In Grafana, go to **Explore**, select the new datasource, and run a simple PromQL query:

```promql
up
```

You should see results from the cluster. If the query returns data, the connection is working.

**When this approach fits:**

- Single cluster or a small number of clusters
- The NOC needs full access to every metric, including rarely-queried ones
- Fast setup is the priority
- The team accepts that dashboard availability depends on cluster health

**When it does not:**

- The NOC monitors many clusters; each one requires a separate datasource and separate token management
- Dashboard load from multiple analysts creates noticeable pressure on Thanos
- The NOC needs metrics to survive a cluster outage
- The NOC needs longer retention than what the cluster provides

---

### Approach 2: Push Metrics to the NOC using Remote-Write

This approach runs the monitoring stack on the NOC's own infrastructure and configures each OpenShift cluster to push metrics to it. The NOC's Grafana then queries local data with no dependency on the cluster being healthy at query time. In this example we will standup a new Promethues and Grafana instance.

**Prerequisites:**

- A RHEL server (or any Linux host)
- Podman installed (`sudo dnf install -y podman` on RHEL 9)
- Network connectivity from the OpenShift cluster to the server on port 9090
- Firewall rules allowing inbound TCP on port 9090

---

#### Step 1: Create the NOC Prometheus

This script creates the directory structure, generates a minimal Prometheus configuration, and starts Prometheus as a Podman container with the remote-write receiver enabled.

📄 [1-noc-prometheus.sh](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/external-noc-openshift-monitoring/1-noc-prometheus.sh)

```bash
bash 1-noc-prometheus.sh
```

The script does the following:

- **Creates a Podman network** called `noc-monitoring`. Both containers join this network so Grafana can reach Prometheus by container name (`noc-prometheus`) rather than `localhost`. Without a shared network, each container's `localhost` refers to its own loopback — Grafana would not be able to reach Prometheus.
- **Creates `/opt/noc-monitoring/`** with subdirectories for Prometheus configuration and data.
- **Generates the Prometheus config** — a minimal `prometheus.yml` with only a self-scrape job. This Prometheus instance does not scrape the OpenShift cluster. OpenShift pushes metrics via remote-write, so Prometheus only needs to monitor itself.
- **Sets ownership** on the data directory. Prometheus runs as UID 65534 (`nobody`) inside the container. The `:Z` flag on volume mounts handles SELinux relabeling on RHEL.
- **Starts Prometheus** on the `noc-monitoring` network with `--web.enable-remote-write-receiver` — this is the flag that tells Prometheus to accept incoming metrics on `/api/v1/write`. Without it, remote-write requests return a 404. Retention is set to 30 days with `--storage.tsdb.retention.time=30d`.

**Verify Prometheus is running and accepting remote-write:**

```bash
curl -s http://localhost:9090/-/ready
```

```
Prometheus Server is Ready.
```

---

#### Step 2: Create the NOC Grafana

This script starts Grafana as a Podman container and provisions a datasource that points at the local Prometheus instance. The datasource is available immediately on first login with no manual setup.

📄 [2-noc-grafana.sh](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/external-noc-openshift-monitoring/2-noc-grafana.sh)

```bash
bash 2-noc-grafana.sh
```

The script does the following:

- **Creates the Grafana directories** under `/opt/noc-monitoring/` for provisioning files and persistent data.
- **Generates the datasource provisioning file** — tells Grafana to connect to `http://noc-prometheus:9090`, using the container name from the shared Podman network created in Step 1. No manual datasource configuration is needed.
- **Sets ownership** on the data directory. Grafana runs as UID 472 inside the container. The `:Z` flag handles SELinux relabeling on RHEL.
- **Starts Grafana** on the `noc-monitoring` network with the provisioning directory mounted.

**Verify Grafana is running:**

```bash
curl -s http://localhost:3000/api/health | python3 -m json.tool
```

```json
{
    "commit": "...",
    "database": "ok",
    "version": "..."
}
```

Log into Grafana at `http://<noc-server>:3000` with `admin / changeme` and change the password immediately. The **OpenShift Metrics** datasource should already appear under **Connections > Data sources**.

---

#### Step 3: Configure OpenShift to Remote-Write to the NOC Prometheus

On the OpenShift cluster, the `cluster-monitoring-config` ConfigMap in `openshift-monitoring` controls the platform Prometheus behavior. Adding a `remoteWrite` section tells it to push every metric it collects to the NOC endpoint.

📄 [3-cluster-remote-write.yaml](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/external-noc-openshift-monitoring/3-cluster-remote-write.yaml)

```bash
oc apply -f 3-cluster-remote-write.yaml
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
    prometheusK8s:
      externalLabels:
        cluster_name: production-east
      remoteWrite:
      - url: "https://noc-prometheus.example.com:9090/api/v1/write"
        tlsConfig:
          insecureSkipVerify: false
          ca:
            name: noc-prometheus-ca
            key: ca.crt
```

Replace `noc-prometheus.example.com` with the actual hostname or IP of the NOC server. Here is what each setting does:

- **`externalLabels.cluster_name: production-east`** — attaches a `cluster_name` label to every metric sent via remote-write. When the NOC receives metrics from multiple clusters, this label is how Grafana distinguishes them. Choose a value that is meaningful to the NOC team — a cluster name, location, or environment identifier. Note: OpenShift reserves the labels `cluster`, `prometheus`, and `prometheus_replica` for internal use — the admission webhook will reject any of those as external labels.
- **`remoteWrite.url`** — the NOC Prometheus endpoint. The path `/api/v1/write` is the standard Prometheus remote-write receiver endpoint.
- **`tlsConfig`** — for production, the NOC Prometheus endpoint should be behind TLS. Create a ConfigMap or Secret named `noc-prometheus-ca` in the `openshift-monitoring` namespace containing the CA certificate that signed the NOC server's TLS certificate. If you are testing in a lab without TLS, you can set `insecureSkipVerify: true` or use an `http://` URL — but do not do this in production.
- **`enableUserWorkload: true`** — also ships metrics from user-deployed workloads, not just platform components.

> **Important:** If a `cluster-monitoring-config` ConfigMap already exists on your cluster, merge the `remoteWrite` and `externalLabels` keys into the existing `config.yaml`. Do not replace the entire ConfigMap — doing so can remove settings that other components depend on, such as `additionalAlertmanagerConfigs` or custom `nodeExporter` collectors.

After applying, the Cluster Monitoring Operator restarts the Prometheus pods to pick up the new configuration. Watch for them to come back:

```bash
oc get pods -n openshift-monitoring -l app.kubernetes.io/name=prometheus -w
```

```
NAME                 READY   STATUS    RESTARTS   AGE
prometheus-k8s-0     6/6     Running   0          45s
prometheus-k8s-1     6/6     Running   0          30s
```

Both pods should reach `Running` with all containers ready within a minute or two.

**Verify remote-write is active** by checking the Prometheus logs for write activity:

```bash
oc logs -n openshift-monitoring prometheus-k8s-0 -c prometheus --tail=20 | grep -i remote
```

You should see log lines indicating the remote-write endpoint is configured. If you see errors about connection refused or TLS failures, check network connectivity and the TLS configuration.

**Verify metrics are arriving at the NOC Prometheus:**

On the NOC server, query for the `up` metric filtered to the cluster label:

```bash
curl -s 'http://localhost:9090/api/v1/query?query=up{cluster_name="production-east"}' | python3 -m json.tool | head -20
```

If this returns results, metrics are flowing from the cluster to the NOC.

---

#### Step 4: Filter Metrics to Control What Gets Shipped

By default, remote-write sends every metric the platform Prometheus collects. On a moderately sized cluster, this is tens of thousands of time series. The NOC likely does not need all of them: node health, pod status, and alert state are usually enough for an operations center.

The `writeRelabelConfigs` option filters metrics before they leave the cluster. Only series matching the filter are sent. This reduces network bandwidth, lowers storage costs on the NOC side, and keeps the NOC dashboards focused on what operators actually watch.

📄 [4-cluster-remote-write-filtered.yaml](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/external-noc-openshift-monitoring/4-cluster-remote-write-filtered.yaml)

```bash
oc apply -f 4-cluster-remote-write-filtered.yaml
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
    prometheusK8s:
      externalLabels:
        cluster_name: production-east
      remoteWrite:
      - url: "https://noc-prometheus.example.com:9090/api/v1/write"
        tlsConfig:
          insecureSkipVerify: false
          ca:
            name: noc-prometheus-ca
            key: ca.crt
        writeRelabelConfigs:
        - sourceLabels: [__name__]
          regex: 'node_.+|kube_node_.+|kube_pod_.+|container_cpu_.+|container_memory_.+|machine_.+|up|ALERTS|ALERTS_FOR_STATE'
          action: keep
```

The `writeRelabelConfigs` block uses Prometheus relabeling to filter the outgoing stream. The `keep` action means: only send series whose `__name__` matches the regex. Everything else is silently dropped before it leaves the cluster.

Here is what each pattern covers:

| Pattern | What it captures |
|---|---|
| `node_.+` | Node exporter metrics — CPU, memory, disk, network, load averages |
| `kube_node_.+` | Kubernetes node status — conditions, capacity, allocatable resources |
| `kube_pod_.+` | Pod lifecycle — restarts, phase, container status, resource requests/limits |
| `container_cpu_.+` | Container CPU usage (usage seconds, throttling) |
| `container_memory_.+` | Container memory usage (working set, RSS, cache) |
| `machine_.+` | Machine-level capacity — total CPU cores, total memory |
| `up` | Whether each scrape target is reachable — the most basic health signal |
| `ALERTS` | Currently firing alerts — lets the NOC see alert state without a separate AlertManager integration |
| `ALERTS_FOR_STATE` | How long each alert has been in its current state |

This is a starting point. After running with this filter for a few days, review which metrics the NOC dashboards actually query and tighten the regex. The goal is the smallest set that keeps every NOC dashboard functional.

**Verify the filter is working** by comparing the series count on the cluster versus the NOC:

On the cluster:

```bash
oc exec -n openshift-monitoring prometheus-k8s-0 -c prometheus -- \
  promtool query instant http://localhost:9090 'count({__name__=~".+"})' 2>/dev/null
```

On the NOC server:

```bash
curl -s 'http://localhost:9090/api/v1/query?query=count({__name__=~".%2B"})' | python3 -m json.tool
```

The NOC count should be significantly lower than the cluster count — typically 10-30% of the total, depending on how tight the filter is.

---

#### Step 5: Build NOC Dashboards

With metrics flowing, open Grafana at `http://<noc-server>:3000` and go to **Explore**. Select the **OpenShift Metrics** datasource and run a query:

```promql
node_memory_MemAvailable_bytes{cluster_name="production-east"}
```

If you are monitoring multiple clusters, each one appears as a separate value for the `cluster_name` label. Build dashboards with a `cluster_name` variable at the top so the NOC can switch between clusters or view all of them at once.

A few useful starting queries for a NOC dashboard:

| Panel | PromQL |
|---|---|
| **Node CPU usage** | `1 - avg by (instance, cluster_name) (rate(node_cpu_seconds_total{mode="idle"}[5m]))` |
| **Node memory usage** | `1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)` |
| **Pod restarts (last hour)** | `increase(kube_pod_container_status_restarts_total[1h]) > 0` |
| **Pods not running** | `kube_pod_status_phase{phase!="Running",phase!="Succeeded"} > 0` |
| **Cluster reachability** | `up{job="kubelet"}` |
| **Active alerts** | `ALERTS{alertstate="firing"}` |

---

## Adding More Clusters

For approach 2, adding a second cluster is a one-step operation. Apply the same `cluster-monitoring-config` ConfigMap on the new cluster with a different `externalLabels.cluster` value:

```yaml
externalLabels:
  cluster_name: production-west
```

Point its `remoteWrite.url` at the same NOC Prometheus endpoint. The metrics arrive with their own cluster label and show up in Grafana immediately. No changes are needed on the NOC side — the Prometheus instance accepts remote-write from any source that can reach it.

As the number of clusters grows, monitor the NOC Prometheus for resource pressure. Check `prometheus_tsdb_head_series` to track how many active time series it is storing, and `prometheus_remote_storage_samples_in_total` to see the ingest rate. If you outgrow a single Prometheus, consider Thanos Receive or Cortex as a horizontally scalable replacement that uses the same remote-write protocol.

---

## Which Approach Should You Use?

| | Direct Query (Thanos) | Remote-Write (Prometheus) |
|---|---|---|
| **Setup time** | 15 minutes | 30 minutes |
| **NOC infrastructure** | Grafana only | Prometheus + Grafana |
| **Cluster dependency** | Every query hits the cluster | Fire-and-forget — no query-time dependency |
| **Outage resilience** | Lost when cluster is unreachable | Metrics survive cluster outage |
| **Retention** | Cluster-controlled (15d platform, 24h user workload) | NOC-controlled (30d, 90d, whatever you set) |
| **Multi-cluster** | One datasource per cluster | Single Prometheus receives from all clusters |
| **Bandwidth** | On-demand at query time | Continuous stream (filterable) |
| **Full metric access** | Every metric the cluster collects | Only what you configure in `writeRelabelConfigs` |
| **Best for** | Dev/test, single cluster, full exploration | Production NOC, multi-cluster, resilience matters |

Both approaches can coexist. Some teams use direct query for ad-hoc debugging and investigation while remote-write feeds the NOC's standing dashboards. The two serve different audiences with different needs.

---

## References

- [Extending OpenShift Monitoring: Exporting Metrics and Building Custom Dashboards](/2026/04/01/extending-openshift-monitoring/) — covers service account setup, Thanos access, and in-cluster Grafana deployment
- [Red Hat Documentation: Configuring remote write storage](https://docs.redhat.com/en/documentation/monitoring_stack_for_red_hat_openshift/4.20/html-single/configuring_core_platform_monitoring/index#configuring-remote-write-storage_configuring-metrics) — official reference for the `remoteWrite` configuration in `cluster-monitoring-config`
- [Prometheus Documentation: Remote write configuration](https://prometheus.io/docs/prometheus/latest/configuration/configuration/#remote_write) — full specification for remote-write options including authentication, TLS, and relabeling
