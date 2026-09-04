---
layout: post
title: "Observing Network Flows Across a 5G Core on OpenShift with Network Observability"
date: 2026-07-17
---

OpenShift ships with a powerful network observability stack built on eBPF — it captures every flow between every pod without injecting sidecars or modifying applications. But seeing it in action requires an application worth observing. A single-namespace deployment with a frontend and a database does not generate the kind of cross-namespace, multi-protocol traffic that makes network observability interesting. A 5G core network does. This is a quick why and how-to for deploying the Network Observability Operator alongside a full Open5GS 5G core, observing its inter-namespace flows in the console, and using the on-demand CLI to capture packets when things go wrong.

## Why This Matters

Most teams install the Network Observability Operator as a checkbox item — it is available, it sounds useful, they enable it. Then they open the console plugin, see a wall of flows between `openshift-*` namespaces, and close the tab. The operator becomes shelfware because no one built a mental model of what the data means or how to use it when something breaks.

The gap is not in the tooling. The gap is in having a workload that generates traffic patterns worth understanding. A 5G core is that workload. Open5GS deploys eleven network functions across three namespaces, each talking to the others over distinct protocols — HTTP/2 for the Service Based Interface, PFCP over UDP between the session manager and user plane, SCTP for radio access connections, and TCP for database access. When you look at the Network Observability topology view with this running, you see a real network — not a flat diagram, but a living map of which components talk to which, how much data moves between them, and where the bottlenecks are.

That visibility becomes operational when something goes wrong. A misconfigured NetworkPolicy that blocks registration traffic shows up as packet drops in the flow table. Latency injected on a pod interface surfaces as elevated round-trip times. A DNS failure appears as failed queries in the DNS tracking panel. Each of these is a signal that tells you where to point the on-demand packet capture CLI — and once you capture, you have a pcapng file with Kubernetes metadata embedded directly in it, so Wireshark shows you pod names alongside packet headers.

This post builds the whole pipeline: install the observability stack, deploy the 5G core, observe it working, break it in three different ways, and capture the evidence.

---

## The Steps

1. Deploy MinIO as lightweight S3-compatible object storage for Loki
2. Install the Loki Operator and create a LokiStack for flow log storage
3. Install the Network Observability Operator and create a FlowCollector with DNS tracking, packet drop detection, and round-trip time measurement enabled
4. Deploy an Open5GS 5G core across three namespaces — core infrastructure, control plane, and user plane — with a traffic generator to produce continuous cross-namespace flows
5. Explore the network flows in the OpenShift console topology and flow table views
6. Simulate three traffic issues — a NetworkPolicy drop, latency injection, and a DNS failure — and observe each in the console
7. Use the `oc netobserv` CLI to capture packets on demand and analyze them in Wireshark

---

## How To Do It

This walkthrough assumes an OpenShift 4.18 or later cluster with cluster-admin access and the `oc` CLI installed. A single-node or multi-node cluster both work. The `oc netobserv` CLI plugin is installed separately in Step 7. You will also need Wireshark on your local machine to analyze packet captures.

### Step 1: Deploy MinIO for Object Storage

The Network Observability Operator stores flow logs in Loki, and Loki requires S3-compatible object storage. On a cluster without AWS S3 or OpenShift Data Foundation, the simplest option is a standalone MinIO instance. This is appropriate for demos and development — production deployments should use a supported storage backend.

📄 [1-minio.yaml](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/network-observability-open5gs/1-minio.yaml)

```bash
oc apply -f 1-minio.yaml
```

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: minio
---
apiVersion: v1
kind: Secret
metadata:
  name: minio-secret
  namespace: minio
type: Opaque
stringData:
  MINIO_ROOT_USER: minioadmin
  MINIO_ROOT_PASSWORD: minioadmin123
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio-pvc
  namespace: minio
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 20Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: minio
spec:
  replicas: 1
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
      containers:
        - name: minio
          image: quay.io/minio/minio:latest
          args:
            - server
            - /data
            - --console-address
            - ":9090"
          env:
            - name: MINIO_ROOT_USER
              valueFrom:
                secretKeyRef:
                  name: minio-secret
                  key: MINIO_ROOT_USER
            - name: MINIO_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: minio-secret
                  key: MINIO_ROOT_PASSWORD
          ports:
            - containerPort: 9000
              name: api
            - containerPort: 9090
              name: console
          volumeMounts:
            - name: data
              mountPath: /data
          livenessProbe:
            httpGet:
              path: /minio/health/live
              port: 9000
            initialDelaySeconds: 10
            periodSeconds: 20
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: minio-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: minio
spec:
  selector:
    app: minio
  ports:
    - port: 9000
      targetPort: 9000
      name: api
    - port: 9090
      targetPort: 9090
      name: console
  type: ClusterIP
```

The file creates five resources. The **Namespace** isolates MinIO from the observability stack. The **Secret** stores MinIO root credentials — change these if your cluster is shared. The **PVC** requests 20Gi of storage, which is more than enough for demo flow logs. The **Deployment** runs MinIO in single-server mode with the `--console-address` flag exposing the web console on port 9090. The **Service** exposes both the S3 API (port 9000) and the web console (port 9090) as ClusterIP endpoints.

Verify the MinIO pod is running:

```bash
oc wait --for=condition=Available deployment/minio -n minio --timeout=120s
oc get pods -n minio
```

```
NAME                     READY   STATUS    RESTARTS   AGE
minio-5d4f7b8c9-xk2pj   1/1     Running   0          30s
```

Now create the bucket that Loki will use. This Job runs the MinIO client (`mc`) to create a bucket named `netobserv-loki`. The `MC_CONFIG_DIR` environment variable redirects the client configuration to `/tmp` because OpenShift's default security context does not allow writing to the home directory:

📄 [2-minio-create-bucket.yaml](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/network-observability-open5gs/2-minio-create-bucket.yaml)

```bash
oc apply -f 2-minio-create-bucket.yaml
```

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: minio-create-bucket
  namespace: minio
spec:
  template:
    spec:
      containers:
        - name: mc
          image: quay.io/minio/mc:latest
          command: ["/bin/sh", "-c"]
          env:
            - name: MC_CONFIG_DIR
              value: /tmp/.mc
          args:
            - |
              mc alias set local http://minio.minio.svc.cluster.local:9000 minioadmin minioadmin123 &&
              mc mb --ignore-existing local/netobserv-loki &&
              echo "Bucket netobserv-loki created successfully"
      restartPolicy: Never
  backoffLimit: 3
```

Verify the Job completed:

```bash
oc wait --for=condition=Complete job/minio-create-bucket -n minio --timeout=60s
oc logs job/minio-create-bucket -n minio
```

```
Bucket created successfully `local/netobserv-loki`.
Bucket netobserv-loki created successfully
```

---

### Step 2: Install the Loki Operator and Create the LokiStack

The Network Observability Operator sends enriched flow logs to Loki for storage and querying. The Loki Operator manages the LokiStack lifecycle — deploying ingesters, queriers, and compactors — and integrates with OpenShift's authentication for multi-tenant access.

> If the Loki Operator is already installed on your cluster (common when OpenShift Logging is deployed), skip the subscription step below and proceed directly to creating the LokiStack. You can check with `oc get csv -A | grep loki`. If a Loki Operator CSV shows `Succeeded` in any namespace, the operator is already available cluster-wide and creating a second subscription will cause an OperatorGroup conflict.

If the Loki Operator is not installed, create a Subscription. The `openshift-operators-redhat` namespace and its OperatorGroup should already exist on most clusters — if not, create them first:

📄 [3-loki-operator.yaml](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/network-observability-open5gs/3-loki-operator.yaml)

```bash
oc apply -f 3-loki-operator.yaml
```

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: loki-operator
  namespace: openshift-operators-redhat
spec:
  channel: stable-6.2
  installPlanApproval: Automatic
  name: loki-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
```

Wait for the Loki Operator CRD to be available:

```bash
oc wait --for condition=established --timeout=180s crd/lokistacks.loki.grafana.com
oc get csv -A | grep loki | head -1
```

```
loki-operator   loki-operator.v6.5.1   Loki Operator   6.5.1   Succeeded
```

Now create the LokiStack. This deploys the actual Loki instance in the `netobserv` namespace, with an S3 secret pointing to the MinIO bucket created in Step 1:

📄 [4-lokistack.yaml](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/network-observability-open5gs/4-lokistack.yaml)

```bash
oc apply -f 4-lokistack.yaml
```

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: netobserv
---
apiVersion: v1
kind: Secret
metadata:
  name: netobserv-loki-s3
  namespace: netobserv
stringData:
  access_key_id: minioadmin
  access_key_secret: minioadmin123
  bucketnames: netobserv-loki
  endpoint: http://minio.minio.svc.cluster.local:9000
  region: us-east-1
---
apiVersion: loki.grafana.com/v1
kind: LokiStack
metadata:
  name: netobserv-loki
  namespace: netobserv
spec:
  managementState: Managed
  size: 1x.demo
  storage:
    schemas:
      - effectiveDate: "2022-06-01"
        version: v13
    secret:
      name: netobserv-loki-s3
      type: s3
  storageClassName: gp3-csi
  tenants:
    mode: openshift-network
  limits:
    global:
      ingestion:
        ingestionRate: 20
        ingestionBurstSize: 40
      queries:
        maxEntriesLimitPerQuery: 10000
        maxQuerySeries: 5000
      retention:
        days: 7
```

Three resources here. The **Namespace** `netobserv` is where all network observability workload pods will run. The **Secret** contains the S3 credentials pointing to MinIO. The `region` is set to `us-east-1` because MinIO requires a region string even though it does not enforce regions.

The **LokiStack** CR is where the important decisions live:

- **`size: 1x.demo`** is a minimal, non-HA deployment suitable for demos. It is not visible in the web console UI — it must be applied via CLI. For production, use `1x.extra-small` or larger.
- **`storageClassName`** must match a StorageClass available on your cluster. Run `oc get sc` to find yours. Common options are `gp3-csi` (AWS), `ocs-external-storagecluster-ceph-rbd` (ODF), `thin-csi` (vSphere), or `lvms-vg1` (LVM Storage).
- **`tenants.mode: openshift-network`** configures Loki for network flow storage with the correct tenant structure and RBAC integration. Using `openshift-logging` here would break network observability.
- **`limits.global.ingestion`** increases the ingestion rate from the default 4MB/s to 20MB/s. The default is too low for network flow data even at moderate sampling rates.
- **`limits.global.queries.maxQuerySeries: 5000`** increases the maximum number of series a single query can return from the default of 500. Network flow queries naturally produce high-cardinality results — every unique source/destination pair is a separate series.

Wait for the LokiStack pods to come up:

```bash
oc wait --for=jsonpath='{.status.conditions[?(@.type=="Ready")].status}'=True \
  lokistack/netobserv-loki -n netobserv --timeout=300s
oc get pods -n netobserv -l app.kubernetes.io/instance=netobserv-loki
```

The LokiStack may take 2-3 minutes to fully deploy. All pods should reach `Running` before continuing.

#### Grant Loki Read Access

The Loki gateway uses an OPA (Open Policy Agent) sidecar to authorize queries. The console plugin passes the logged-in user's token to Loki, and OPA checks whether that user has permission to read network flow logs. Two pieces of RBAC are needed:

📄 [4a-loki-netobserv-rbac.yaml](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/network-observability-open5gs/4a-loki-netobserv-rbac.yaml)

```bash
oc apply -f 4a-loki-netobserv-rbac.yaml
```

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: netobserv-loki-reader-authenticated
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: netobserv-loki-reader
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: Group
    name: system:authenticated
```

This grants all authenticated users the ability to query flow logs from Loki. In a production cluster, you would bind this to specific groups or users instead.

The OPA sidecar also has an admin group bypass — it allows users in `system:cluster-admins`, `cluster-admin`, or `dedicated-admin` **groups** to query flows across all namespaces without specifying exact namespace selectors in the query. If your cluster-admin user was provisioned through an identity provider (Keycloak, HTPasswd, LDAP) rather than the built-in `kubeadmin`, they may not be in any of these groups by default. Verify with:

```bash
oc get groups
```

If your admin user is not listed in one of the OPA admin groups, add them. For example, if your admin user is named `admin`:

```bash
oc adm groups new cluster-admin admin 2>/dev/null || oc adm groups add-users cluster-admin admin
```

Without this, the Network Traffic console will show `400 Bad Request` errors with the message `wildcard in query namespaces not allowed` when trying to view the topology or flow table.

---

### Step 3: Install the Network Observability Operator and Create the FlowCollector

The Network Observability Operator deploys eBPF agents on every node, a flow processing pipeline, and a console plugin that adds network traffic views to the OpenShift web console.

📄 [5-netobserv-operator.yaml](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/network-observability-open5gs/5-netobserv-operator.yaml)

```bash
oc apply -f 5-netobserv-operator.yaml
```

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-netobserv-operator
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-netobserv-operator
  namespace: openshift-netobserv-operator
spec:
  upgradeStrategy: Default
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: netobserv-operator
  namespace: openshift-netobserv-operator
spec:
  channel: stable
  installPlanApproval: Automatic
  name: netobserv-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
```

Wait for the operator CRD to be available:

```bash
oc wait --for condition=established --timeout=180s crd/flowcollectors.flows.netobserv.io
oc get csv -n openshift-netobserv-operator | grep netobserv
```

Now create the FlowCollector — the central configuration resource that tells the operator what to observe and how:

📄 [6-flowcollector.yaml](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/network-observability-open5gs/6-flowcollector.yaml)

```bash
oc apply -f 6-flowcollector.yaml
```

```yaml
apiVersion: flows.netobserv.io/v1beta2
kind: FlowCollector
metadata:
  name: cluster
spec:
  namespace: netobserv
  deploymentModel: Direct
  agent:
    type: eBPF
    ebpf:
      sampling: 50
      privileged: true
      features:
        - DNSTracking
        - PacketDrop
        - FlowRTT
        - NetworkEvents
        - PacketTranslation
  loki:
    enable: true
    mode: LokiStack
    lokiStack:
      name: netobserv-loki
      namespace: netobserv
  consolePlugin:
    register: true
    portNaming:
      enable: true
    quickFilters:
      - name: Open5GS
        default: true
        filter:
          src_namespace: "open5gs-"
          dst_namespace: "open5gs-"
      - name: Applications
        filter:
          src_namespace!: "openshift-,netobserv"
          dst_namespace!: "openshift-,netobserv"
      - name: Infrastructure
        filter:
          src_namespace: "openshift-,netobserv"
          dst_namespace: "openshift-,netobserv"
      - name: Pods network
        filter:
          src_kind: Pod
          dst_kind: Pod
  processor:
    logTypes: Flows
```

This FlowCollector is configured for maximum observability:

- **`sampling: 50`** samples one in every fifty packets. This is the default and balances visibility with CPU overhead. Setting this to `1` (every packet) generates complete data but can overwhelm the `1x.demo` LokiStack ingestion rate.
- **`privileged: true`** mounts the kernel debug filesystem, which is required for `PacketDrop` and `NetworkEvents` features.
- **`features`** enables five eBPF capabilities:
  - **DNSTracking** — parses DNS query and response packets to extract domain names, latency, and response codes
  - **PacketDrop** — hooks into the kernel's `kfree_skb` tracepoint to detect dropped packets and report the drop cause
  - **FlowRTT** — reads TCP smoothed round-trip time from the socket via `tcp_rcv_established`
  - **NetworkEvents** — captures OVN-Kubernetes network policy hits (requires OCP 4.18+ with OVN-Kubernetes)
  - **PacketTranslation** — tracks NAT source/destination translation
- **`mode: LokiStack`** automatically configures the Loki connection URL, TLS certificates, tenant ID, and authentication token. No manual RBAC for the flowlogs-pipeline is needed — the operator creates the necessary ClusterRoleBindings automatically.
- **`quickFilters`** adds an "Open5GS" filter to the console plugin that shows only traffic between the `open5gs-*` namespaces.
- **`logTypes: Flows`** logs individual flow records. Note the capitalization — `FLOWS` is not valid and will be rejected by the API.

Verify the FlowCollector is ready and the eBPF agents are running:

```bash
oc get flowcollector cluster
```

```
NAME      AGENT   PROCESSOR   PLUGIN   SAMPLING   DEPLOYMENT MODEL   STATUS
cluster   Ready   Ready       Ready    50         Direct             Ready
```

```bash
oc get pods -n netobserv-privileged
```

On a multi-node cluster you will see one eBPF agent pod per node. Also verify the flowlogs-pipeline and console plugin are running in the `netobserv` namespace:

```bash
oc get pods -n netobserv -l app=flowlogs-pipeline
oc get pods -n netobserv -l app=netobserv-plugin
```

If the **Network Traffic** menu entry does not appear under **Observe** in the console, manually register the plugin:

```bash
oc patch console.operator cluster --type json \
  -p '[{"op": "add", "path": "/spec/plugins/-", "value": "netobserv-plugin"}]'
```

---

### Step 4: Deploy the Open5GS 5G Core

The 5G core is a service-based architecture where each network function (NF) runs as an independent microservice. Every NF registers with the Network Repository Function (NRF) over the Service Based Interface (SBI) — HTTP/2 on port 7777. The Service Communication Proxy (SCP) acts as a routing proxy between NFs, so each NF only needs to know the SCP address rather than discovering every other NF directly.

The deployment is split across three namespaces to maximize the number of cross-namespace flows that Network Observability can observe:

| Namespace | Components | Role |
|---|---|---|
| `open5gs-core` | NRF, SCP, MongoDB | Service registry and data store — every other NF connects here |
| `open5gs-control` | AMF, SMF, AUSF, UDM, UDR, PCF, NSSF, BSF | Control plane — handles signaling, authentication, session management, and policy |
| `open5gs-data` | UPF | User plane — forwards data packets between the radio network and the internet |

This split creates cross-namespace traffic on multiple protocols:

| Flow | Protocol | Port | Direction |
|---|---|---|---|
| All NFs → NRF | HTTP/2 (SBI) | 7777 | control → core |
| All NFs → SCP | HTTP/2 (SBI) | 7777 | control → core |
| UDR, PCF → MongoDB | TCP | 27017 | control → core |
| SMF → UPF | PFCP (UDP) | 8805 | control → data |

#### Load the SCTP Kernel Module

The AMF uses SCTP for the N2 (NGAP) interface to the radio access network. The SCTP kernel module may not be loaded by default on your OpenShift nodes. Load it before deploying the control plane:

```bash
for NODE in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do
  echo "Loading SCTP on $NODE..."
  oc debug node/$NODE -- chroot /host modprobe sctp 2>/dev/null
done
```

#### Deploy the Data Plane First

The SMF resolves the UPF hostname (`upf.open5gs-data.svc.cluster.local`) at startup and will crash if the Service does not exist yet. Deploy the data plane namespace before the control plane:

📄 [9-open5gs-data.yaml](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/network-observability-open5gs/9-open5gs-data.yaml)

```bash
oc apply -f 9-open5gs-data.yaml
oc adm policy add-scc-to-user privileged -z open5gs-sa -n open5gs-data
oc rollout restart deployment/upf -n open5gs-data
oc wait --for=condition=Available deployment/upf -n open5gs-data --timeout=120s
```

The UPF requires elevated privileges. An init container runs with `privileged: true` to create a TUN device (`ogstun`), configure IP forwarding, and set up NAT masquerading. The main container also runs as privileged because it needs continued access to the TUN device.

#### Deploy the Core Infrastructure

📄 [7-open5gs-core.yaml](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/network-observability-open5gs/7-open5gs-core.yaml)

```bash
oc apply -f 7-open5gs-core.yaml
oc adm policy add-scc-to-user anyuid -z open5gs-sa -n open5gs-core
oc rollout restart deployment -n open5gs-core
oc wait --for=condition=Available deployment --all -n open5gs-core --timeout=120s
```

The `anyuid` SCC is required because the `gradiant/open5gs` image is Debian-based and runs processes as root, which conflicts with OpenShift's default `restricted` SCC.

The core namespace contains MongoDB (data store for subscriber and policy data), NRF (the service registry where all NFs register), and SCP (the service communication proxy that routes SBI traffic between NFs). The NRF and SCP configurations are minimal — the NRF listens on port 7777 with a test PLMN ID (`001/01`), and the SCP points to the NRF for NF discovery.

#### Deploy the Control Plane

📄 [8-open5gs-control.yaml](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/network-observability-open5gs/8-open5gs-control.yaml)

```bash
oc apply -f 8-open5gs-control.yaml
oc adm policy add-scc-to-user anyuid -z open5gs-sa -n open5gs-control
oc rollout restart deployment -n open5gs-control
oc wait --for=condition=Available deployment --all -n open5gs-control --timeout=120s
```

This file contains eight NFs, each with a ConfigMap, Deployment, and Service. A few configuration details worth noting:

- The **AMF** includes a `time.t3512.value: 540` field that sets the periodic registration timer — this is required in Open5GS v2.7.6 and the AMF will fail to start without it.
- The **SMF** includes a `gtpu.server` section alongside its PFCP client configuration — both are required for the SMF to initialize.
- The **UDR** and **PCF** connect to MongoDB. They need the `DB_URI` environment variable set to `mongodb://mongodb.open5gs-core.svc.cluster.local:27017/open5gs` because the `gradiant/open5gs` image does not read the `db_uri` field from custom config files. It falls back to its built-in default (`mongodb://mongo/open5gs`) unless overridden by the environment variable.
- All other NFs (AUSF, UDM, NSSF, BSF) follow the same simple pattern: SBI server on `0.0.0.0:7777`, SBI client pointing to SCP.

#### Deploy the Traffic Generator

The 5G core NFs generate heartbeat and registration traffic every 10 seconds, but that steady-state activity is not enough to make the Network Observability views visually interesting. This traffic generator queries the NRF discovery API, hits each NF's SBI endpoint, and probes cross-namespace service connectivity in a continuous loop:

📄 [13-traffic-generator.yaml](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/network-observability-open5gs/13-traffic-generator.yaml)

```bash
oc apply -f 13-traffic-generator.yaml
```

#### Verify the Deployment

Confirm all pods are running across all three namespaces:

```bash
oc get pods -n open5gs-core
oc get pods -n open5gs-control
oc get pods -n open5gs-data
```

Check the NRF logs for NF registration entries:

```bash
oc logs -n open5gs-core deploy/nrf --tail=20 | grep -i "registered\|NF"
```

You should see `NF registered [Heartbeat:10s]` log lines indicating each NF has registered with the NRF. Check the SMF logs for the PFCP association with the UPF:

```bash
oc logs -n open5gs-control deploy/smf --tail=10 | grep -i "PFCP"
```

A line containing `PFCP associated` confirms the SMF has established a session management path to the UPF across namespaces.

---

### Step 5: Explore Network Flows in the Console

Open the OpenShift web console and navigate to **Observe → Network Traffic**. If the menu entry does not appear, verify the console plugin is registered (see the end of Step 3).

The Network Traffic page has three views:

**Flow Table** — A live table of individual flow records. Select the **Open5GS** quick filter to show only traffic between the `open5gs-*` namespaces. You should see flows on port 7777 (SBI) between every NF and the SCP/NRF in `open5gs-core`, flows on port 27017 (MongoDB) from UDR and PCF to `open5gs-core`, and flows on port 8805 (PFCP) from SMF to UPF across namespaces.

**Topology** — A visual map of network connections. Switch to the topology view and group by namespace. You will see three namespace bubbles (`open5gs-core`, `open5gs-control`, `open5gs-data`) connected by flow lines. Click on a line between `open5gs-control` and `open5gs-core` to see the aggregate traffic — bytes, packets, and protocols. Drill into individual pods to see which NFs generate the most traffic.

**Overview** — Dashboards with aggregate metrics. Look for the DNS latency panel (from `DNSTracking`), the RTT panel (from `FlowRTT`), and the top talkers panel. The DNS panel should show DNS queries from every pod resolving the cross-namespace service names.

---

### Step 6: Simulate Traffic Issues

With the 5G core running and flows visible in the console, the next step is to break things deliberately and observe the impact. Each scenario creates a distinct signal in the Network Observability UI that demonstrates a different eBPF feature.

#### Scenario 1: Block NRF Registration with a NetworkPolicy

Every NF sends periodic heartbeat requests to NRF to maintain its registration. Blocking ingress to NRF forces these heartbeats to fail, which creates packet drops visible in the NetObserv UI.

📄 [10-block-nrf-ingress.yaml](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/network-observability-open5gs/10-block-nrf-ingress.yaml)

```bash
oc apply -f 10-block-nrf-ingress.yaml
```

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: block-nrf-ingress
  namespace: open5gs-core
spec:
  podSelector:
    matchLabels:
      app: nrf
  policyTypes:
    - Ingress
  ingress: []
```

This NetworkPolicy selects the NRF pod and sets an empty ingress rule list — meaning no ingress traffic is allowed. Every SBI request from the control plane NFs to NRF will be dropped by OVN-Kubernetes.

Go back to the Network Traffic console. In the flow table, enable the **Packet drop** column. Within 30-60 seconds you should see flows from the control plane pods to NRF showing non-zero drop counts. The `PktDropLatestDropCause` field tells you why the packet was dropped.

After observing the drops, remove the policy to restore NRF access:

```bash
oc delete networkpolicy block-nrf-ingress -n open5gs-core
```

#### Scenario 2: Inject Latency on the UPF

The FlowRTT feature measures TCP round-trip time by reading the kernel's smoothed RTT value from established connections. Injecting artificial latency on a pod interface makes this metric spike, simulating a network performance degradation. The UPF is the target here because it runs with `privileged` SCC, which grants the `NET_ADMIN` capability that `tc` requires. Control plane pods running with `anyuid` do not have this capability.

📄 [11-inject-latency.sh](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/network-observability-open5gs/11-inject-latency.sh)

```bash
bash 11-inject-latency.sh add
```

The script runs `tc qdisc add dev eth0 root netem delay 500ms` inside the UPF pod, which adds 500 milliseconds of delay to every packet leaving the UPF. Since the UPF maintains PFCP connections to the SMF and SBI connections to the SCP, you will see elevated RTT on flows involving `open5gs-data`. In the Network Traffic console, enable the **RTT** column and filter for the data plane namespace — the `TimeFlowRttNs` values should jump to approximately 500,000,000 nanoseconds.

Remove the latency when done:

```bash
bash 11-inject-latency.sh remove
```

#### Scenario 3: Block DNS Resolution for the Data Plane

📄 [12-block-dns-egress.yaml](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/network-observability-open5gs/12-block-dns-egress.yaml)

```bash
oc apply -f 12-block-dns-egress.yaml
```

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: block-dns-egress
  namespace: open5gs-data
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - ports:
        - port: 8805
          protocol: UDP
        - port: 2152
          protocol: UDP
        - port: 7777
          protocol: TCP
```

This NetworkPolicy allows egress only on the UPF's operational ports — PFCP (8805), GTP-U (2152), and SBI (7777). DNS traffic on port 53 is implicitly blocked. The DNSTracking panel should show DNS queries from `open5gs-data` with no responses, elevated latency, and failed response codes.

Remove the policy to restore DNS:

```bash
oc delete networkpolicy block-dns-egress -n open5gs-data
```

---

### Step 7: Capture Traffic On Demand with the CLI

The `oc netobserv` CLI deploys ephemeral eBPF agents, captures packets or flows, and downloads the results as pcapng files that can be opened in Wireshark. It works independently of the Network Observability Operator — no operator installation is required.

#### Install the CLI

```bash
podman create --name netobserv-cli \
  registry.redhat.io/network-observability/network-observability-cli-rhel9:1.8
podman cp netobserv-cli:/oc-netobserv .
podman rm netobserv-cli
sudo mv oc-netobserv /usr/local/bin/
oc netobserv version
```

#### Capture Packets

To capture the SBI traffic between NFs:

```bash
oc netobserv packets --protocol=TCP --port=7777 --max-bytes=500000000
```

The `--max-bytes` flag increases the capture limit from the default 50MB to 500MB. The CLI displays a live terminal UI with a scrollable table. Press `Ctrl+C` to stop and save the pcapng file to `./output/pcap/`.

#### Capture Flows with Enrichment

For a richer view with Kubernetes metadata, DNS names, RTT, and drop counts:

```bash
oc netobserv flows --enable_all --protocol=TCP --port=7777 --max-bytes=500000000
```

Flow output is saved as both JSON (`./output/flow/*.json`) and SQLite (`./output/flow/*.db`).

#### Capture DNS Traffic

To investigate DNS failures from Scenario 3:

```bash
oc netobserv packets --protocol=UDP --port=53
```

#### Clean Up

The CLI automatically cleans up when you press `Ctrl+C`. For manual cleanup:

```bash
oc netobserv cleanup
```

The pcapng files include Kubernetes metadata as custom blocks. When you open the file in Wireshark, each packet includes contextual information about the source and destination pods — pod name, namespace, and owning Deployment — without cross-referencing multiple tools.

---

## Where To Go From Here

This post deployed a 5G core as a demonstration workload, but the Network Observability Operator works with any application. The topology view, DNS tracking, packet drop detection, and RTT measurement apply equally to microservices architectures, database clusters, or service meshes.

Two extensions that build directly on this setup:

**Add UERANSIM for realistic traffic.** UERANSIM is a 5G UE and gNB simulator that connects to the AMF over NGAP (SCTP port 38412) and generates UE registration, PDU session establishment, and data plane traffic through the UPF. This adds SCTP and GTP-U flows to the topology.

**Export flows to Kafka for external analysis.** The FlowCollector supports exporters that send enriched flow data to Kafka, IPFIX, or OpenTelemetry collectors. Adding a Kafka exporter lets you feed flow data into Splunk, Elasticsearch, or a custom analytics pipeline alongside the console UI.

---

## Cleaning Up

To remove everything deployed in this post:

```bash
oc delete flowcollector cluster
oc delete lokistack netobserv-loki -n netobserv
oc delete subscription netobserv-operator -n openshift-netobserv-operator
oc delete csv -n openshift-netobserv-operator --all
oc delete namespace open5gs-core open5gs-control open5gs-data netobserv minio \
  openshift-netobserv-operator
oc delete namespace netobserv-privileged 2>/dev/null || true
oc delete clusterrolebinding netobserv-loki-reader-authenticated
oc delete group cluster-admin 2>/dev/null || true
```

---

## References

- [OCP Docs: Network Observability Overview](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/network_observability/network-observability-overview)
- [OCP Docs: Installing Network Observability Operators](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/network_observability/installing-network-observability-operators)
- [OCP Docs: Network Observability CLI](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/network_observability/network-observability-cli-1)
- [Red Hat Developer: Network Observability On Demand](https://developers.redhat.com/articles/2024/09/17/network-observability-demand)
- [Red Hat Developer: Network Observability with eBPF on SNO](https://developers.redhat.com/articles/2024/01/25/network-observability-ebpf-single-node-openshift)
- [Red Hat Blog: How We Use eBPF for Network Observability](https://www.redhat.com/en/blog/ebpf-openshift-network-observability)
- [Open5GS Documentation](https://open5gs.org/open5gs/docs/)
- [Gradiant Open5GS Docker Hub](https://hub.docker.com/r/gradiant/open5gs)
- [FlowCollector v1beta2 API Reference](https://github.com/netobserv/network-observability-operator/blob/main/docs/FlowCollector.md)
- [Loki Operator Object Storage Configuration](https://github.com/grafana/loki/blob/main/operator/docs/lokistack/object_storage.md)
