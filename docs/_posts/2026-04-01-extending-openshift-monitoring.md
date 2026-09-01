---
layout: post
title: "Extending OpenShift Monitoring: Exporting Metrics and Building Custom Dashboards"
date: 2026-04-01
---

OpenShift ships with a production-grade monitoring stack — Prometheus, Thanos, and a built-in Observe console — ready to go from day one. This is a quick why and how-to for two ways to extend it: pulling metrics into a CSV and deploying a custom Grafana instance you can actually edit.

## Why This Matters

The built-in dashboards are managed by the Cluster Monitoring Operator (CMO), which keeps them stable and consistent across upgrades. That's the right behavior for platform infrastructure — but it means they're not yours to modify, and the data inside them isn't easy to export.

That gap matters more than people realize. Capacity planning, chargeback reporting, compliance exports, custom application dashboards — these are everyday asks that fall outside what the platform monitoring stack is designed to handle. Most teams hit this and assume it's a dead end.

It isn't. OpenShift exposes the full **Thanos Querier API** to any authorized client. You can query it directly with a Python script and get a CSV, or deploy your own Grafana instance alongside the platform one and build whatever dashboards your team needs — all without touching a single platform component.

---

## The Steps

**Approach 1 — Query Thanos directly and export a CSV**

1. Confirm you're logged into the cluster with `oc`
2. Run `query_thanos.py` with your PromQL query, time range, and output file
3. Open the CSV

**Approach 2 — Deploy a custom Grafana instance**

1. Create a namespace and service account
2. Create a long-lived token secret for that service account
3. Install the Grafana Operator from OperatorHub
4. Deploy a Grafana instance
5. Create a datasource pointing at the Thanos Querier
6. Retrieve your Grafana credentials and log in
7. Build dashboards and export data from the UI

---

## How To Do It

### Approach 1: Query Thanos Directly → CSV

A Python script authenticates against the Thanos Querier route using your existing `oc` session, runs a PromQL range query, and writes the results to a CSV file. No UI, no intermediate steps.

**Prerequisites:**

- `oc` CLI installed and logged in (`oc whoami` should return your username)
- Python 3.10+
- `pip install requests`

**Script:** [query_thanos.py](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/extending-openshift-monitoring/parsePrometheusData/query_thanos.py)

**Run it:**

```bash
python query_thanos.py \
  --query 'sum by (namespace) (container_memory_working_set_bytes{container!=""})' \
  --days 7 \
  --output memory_by_namespace.csv
```

**What it does under the hood:**

At its core, the script is making one authenticated HTTP request to the Thanos query API. You can see the same thing manually with two `oc` commands and a `curl`:

```bash
# Get the external Thanos route URL
export THANOS_URL=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')

# Get your bearer token from the active oc session
export TOKEN=$(oc whoami -t)

# Set a time range (Unix epoch)
export END_TIME=$(date +%s)
export START_TIME=$(date -d "7 days ago" +%s)

# Hit the Thanos range query API directly
curl -k -H "Authorization: Bearer $TOKEN" \
  "https://$THANOS_URL/api/v1/query_range" \
  --data-urlencode 'query=sum(node_namespace_pod_container:container_cpu_usage_seconds_total:sum_irate) by (pod)' \
  --data-urlencode "start=$START_TIME" \
  --data-urlencode "end=$END_TIME" \
  --data-urlencode 'step=3600s' > my_metrics.json
```

The Python script does exactly this — gets the route, grabs the token, calls the same endpoint — then goes one step further: it parses the JSON response and pivots it into a readable CSV instead of leaving it as raw JSON.

**Example output:**

```
DateTime,default,kube-system,openshift-monitoring
2025-03-24T00:00:00.000Z,1073741824,536870912,2147483648
2025-03-24T00:15:00.000Z,1073741824,536870912,2147483648
```

**Options:**

| Flag | Description |
|------|-------------|
| `--query` / `-q` | PromQL query (required) |
| `--days` / `-d` | How many days of history to fetch (required) |
| `--step` / `-s` | Interval between data points, e.g. `15m`, `1h` (optional, auto-calculated) |
| `--label` / `-l` | Label to use as column headers (optional, auto-detected) |
| `--output` / `-o` | Output CSV file path (default: `output.csv`) |

> **Access note:** Your `oc` user needs the `cluster-monitoring-view` cluster role to query Thanos across all namespaces. If you can already see metrics in the OpenShift web console, you likely already have it.

---

### Approach 2: Deploy Your Own Grafana Instance

A full Grafana UI — editable dashboards, panel-level CSV export, ad-hoc PromQL — running in its own namespace and pointed at the same Thanos backend as the platform stack.

---

#### Step 1: Create a Namespace and Service Account

📄 [1-configureNamespaceSA.sh](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/extending-openshift-monitoring/customGrafana/1-configureNamespaceSA.sh)

```bash
oc create namespace my-custom-metrics
oc project my-custom-metrics

oc create sa custom-grafana-sa

oc adm policy add-cluster-role-to-user cluster-monitoring-view -z custom-grafana-sa
```

The `cluster-monitoring-view` role allows the service account to read metrics across all namespaces via Thanos.

---

#### Step 2: Create a Long-Lived Token Secret

📄 [2-SA-secret.yaml](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/extending-openshift-monitoring/customGrafana/2-SA-secret.yaml)

```bash
oc apply -f 2-SA-secret.yaml
```

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: custom-grafana-token
  annotations:
    kubernetes.io/service-account.name: custom-grafana-sa
type: kubernetes.io/service-account-token
```

OCP 4.11+ deprecated `oc sa get-token`. A secret of type `kubernetes.io/service-account-token` annotated with the service account name is the supported replacement — OpenShift automatically populates the `token` key.

---

#### Step 3: Install the Grafana Operator

📄 [3-install-Grafana.yaml](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/extending-openshift-monitoring/customGrafana/3-install-Grafana.yaml)

```bash
oc apply -f 3-install-Grafana.yaml
```

```yaml
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: grafana-operator-group
  namespace: my-custom-metrics
spec:
  targetNamespaces:
  - my-custom-metrics
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: grafana-operator
  namespace: my-custom-metrics
spec:
  channel: v5
  installPlanApproval: Automatic
  name: grafana-operator
  source: community-operators
  sourceNamespace: openshift-marketplace
```

This installs the community Grafana Operator from OperatorHub — the path Red Hat's own documentation points to for custom Grafana on OCP 4. Wait for the operator pod before continuing:

```bash
oc get pods -n my-custom-metrics -w
```

---

#### Step 4: Deploy a Grafana Instance

📄 [4-create-Grafana-instance.yaml](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/extending-openshift-monitoring/customGrafana/4-create-Grafana-instance.yaml)

```bash
oc apply -f 4-create-Grafana-instance.yaml
```

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: Grafana
metadata:
  name: custom-grafana
  namespace: my-custom-metrics
  labels:
    app: grafana
spec:
  route:
    spec: {}
  config:
    log:
      mode: "console"
    auth:
      disable_login_form: "false"
```

`route: spec: {}` tells the operator to create an OpenShift Route automatically. The `app: grafana` label is how the datasource in the next step knows which instance to attach to.

---

#### Step 5: Connect Grafana to the Thanos Querier

📄 [5-create-Grafana-datasource.yaml](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/extending-openshift-monitoring/customGrafana/5-create-Grafana-datasource.yaml)

```bash
oc apply -f 5-create-Grafana-datasource.yaml
```

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: openshift-monitoring-datasource
  namespace: my-custom-metrics
spec:
  instanceSelector:
    matchLabels:
      app: grafana
  valuesFrom:
    - targetPath: "secureJsonData.httpHeaderValue1"
      valueFrom:
        secretKeyRef:
          name: "custom-grafana-token"
          key: "token"
  datasource:
    name: OpenShift Thanos
    type: prometheus
    access: proxy
    url: https://thanos-querier.openshift-monitoring.svc.cluster.local:9091
    isDefault: true
    jsonData:
      tlsSkipVerify: true
      httpHeaderName1: Authorization
    secureJsonData:
      httpHeaderValue1: "Bearer ${token}"
```

A few things worth understanding:

- `thanos-querier.openshift-monitoring.svc.cluster.local:9091` is the in-cluster Thanos service. Port 9091 gives access across all namespaces.
- `valuesFrom` pulls the bearer token from the secret in Step 2 and injects it into the `Authorization` header automatically — no manual token management.
- `tlsSkipVerify: true` is standard for in-cluster service-to-service communication.

---

#### Step 6: Get Your Credentials and Log In

📄 [6-get-grafana-creds.sh](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/extending-openshift-monitoring/customGrafana/6-get-grafana-creds.sh)

```bash
bash 6-get-grafana-creds.sh
```

```
========================================
  Grafana Login Details
========================================
URL:      https://custom-grafana-route-my-custom-metrics.apps.your-cluster.example.com
Username: admin
Password: <generated>
========================================
```

The Grafana Operator stores generated credentials in a secret. This script retrieves and decodes them.

From here you have a fully editable Grafana instance. Use **Explore** for ad-hoc PromQL, or **Dashboards** to build and save views. To export any panel as CSV: panel menu → **Inspect** → **Data** → **Download CSV**.

---

## Which Approach Should You Use?

| | Thanos → CSV (Python) | Custom Grafana |
|---|---|---|
| **Best for** | One-off data pulls, automation, CI pipelines | Ongoing dashboards, visual exploration |
| **Setup** | Minimal — just `oc` and Python | ~10 minutes of YAML |
| **Output** | CSV file | Interactive UI + CSV export |
| **Maintenance** | None | Operator updates, token rotation |

---

## References

- [Red Hat KB: How to export Prometheus metrics into a CSV format in RHOCP4](https://access.redhat.com/solutions/7018296)
- [Red Hat Blog: Custom Grafana dashboards for Red Hat OpenShift Container Platform 4](https://www.redhat.com/en/blog/custom-grafana-dashboards-red-hat-openshift-container-platform-4)
- [Red Hat Cloud Experts: Deploying Grafana on OpenShift 4](https://cloud.redhat.com/experts/o11y/ocp-grafana/)