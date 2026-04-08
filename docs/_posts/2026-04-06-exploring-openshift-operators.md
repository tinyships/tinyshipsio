---
layout: post
title: "How to Find, Install, and Explore an OpenShift Operator from the CLI"
date: 2026-04-06
---

Documentation gets you most of the way there, but operators move fast. Channels get renamed, APIs change between major versions, CRD fields appear and disappear. This is a quick why and how-to for going from zero to a fully installed operator using only `oc` — finding what's available, picking the right channel, applying the subscription, and then walking the CRDs it registers so you understand what you've actually installed before you write a single manifest.

## Why This Matters

The gap between "what the docs say" and "what's actually on your cluster" is where most operator frustration happens. You apply a manifest from a tutorial, get a validation error or a subscription that never resolves, and you're not sure if the problem is your YAML, your cluster version, or an operator that changed its API.

Most people jump straight to the UI or copy a Subscription from a blog post without checking whether that channel even exists on their cluster. Then they wait five minutes wondering why nothing is happening. The CLI gives you the tools to do this right from the start — find the operator, confirm the channel, install it properly, and understand what it registered before you write a single CR.

This is worth slowing down to learn. Once you know how to go from catalog to installed operator entirely in `oc`, you can do it for any operator on any cluster without hunting for the right tutorial.

---

## The Steps

1. Find what operators are available and where they come from
2. Query the OperatorHub catalog to find available channels before subscribing
3. Create the namespace, OperatorGroup, and Subscription to install the operator
4. Wait for the CSV to confirm a successful install
5. Find what CRDs the operator actually registered
6. Use `oc explain` to walk the CRD spec interactively

---

## How To Do It

### Step 1: Find What Operators Are Available

Before you know which operator you want, it helps to understand where they come from. OpenShift pulls its operator catalog from `CatalogSource` objects — these are the upstream feeds that populate OperatorHub. By default, a fresh cluster has three:

```bash
oc get catalogsource -n openshift-marketplace
```

```
NAME                  DISPLAY               TYPE   PUBLISHER   AGE
certified-operators   Certified Operators   grpc   Red Hat     10d
community-operators   Community Operators   grpc   Red Hat     10d
redhat-operators      Red Hat Operators     grpc   Red Hat     10d
```

`redhat-operators` is the source for first-party Red Hat products like Logging, OpenShift Data Foundation, and ACM. `certified-operators` covers ISV software that's gone through Red Hat's certification process. `community-operators` is OperatorHub.io content — open source, community-maintained.

Every operator in those catalogs becomes a `PackageManifest` on your cluster. To list everything available:

```bash
oc get packagemanifest -n openshift-marketplace
```

That list is long. To filter it down to what you're looking for, you can grep on name:

```bash
oc get packagemanifest -n openshift-marketplace | grep -i logging
```

Or filter by catalog source using a label selector:

```bash
oc get packagemanifest -n openshift-marketplace \
  -l catalog=redhat-operators | grep -i logging
```

If you want to search from the web console instead, go to **Operators → OperatorHub**. There's a search bar at the top that filters by name as you type. The left panel lets you narrow by source (Red Hat, Certified, Community), category (Logging & Tracing, Storage, Security, etc.), and capability level. It's the fastest way to browse if you don't know the exact package name yet — the CLI approach is more reliable when you already know what you want and need scriptable output.

---

### Step 2: Find the Right Channel Before You Subscribe

Operator subscriptions require a `channel` field. Documentation often shows `stable`, but many operators publish versioned channels like `stable-6.5` and don't maintain a generic alias. Subscribing to a non-existent channel fails silently — the subscription sits unresolved.

Query the OperatorHub catalog first:

```bash
oc get packagemanifest cluster-logging \
  -o jsonpath='{.status.channels[*].name}'
```

```
stable-6.2 stable-6.3 stable-6.4 stable-6.5
```

Then check which channel the operator recommends as default:

```bash
oc get packagemanifest cluster-logging \
  -o jsonpath='{.status.defaultChannel}'
```

```
stable-6.5
```

Use that value in your `Subscription`. If you want to pin to a specific version rather than float to the latest, use an exact channel like `stable-6.4`.

You can also check what CSV (operator version) each channel points to before subscribing:

```bash
oc get packagemanifest cluster-logging \
  -o jsonpath='{range .status.channels[*]}{.name}{"\t"}{.currentCSV}{"\n"}{end}'
```

```
stable-6.2    cluster-logging.v6.2.0
stable-6.3    cluster-logging.v6.3.0
stable-6.4    cluster-logging.v6.4.0
stable-6.5    cluster-logging.v6.5.0
```

---

### Step 3: Create the Namespace, OperatorGroup, and Subscription

Three resources are required to install an operator via OLM from the CLI. None of them are created by OperatorHub automatically when you're working in the terminal.

**Namespace** — operators install into a specific namespace. For Logging, that's `openshift-logging`. Create it first if it doesn't exist:

```bash
oc create namespace openshift-logging
```

**OperatorGroup** — tells OLM which namespaces the operator is allowed to watch. A single-namespace OperatorGroup scopes the operator to `openshift-logging` only, which is correct for Logging. Without an OperatorGroup in the namespace, the Subscription will stall:

```bash
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-logging
  namespace: openshift-logging
spec:
  targetNamespaces:
  - openshift-logging
EOF
```

**Subscription** — this is what actually triggers OLM to pull and install the operator. It references the catalog source (`redhat-operators`), the package name (`cluster-logging`), and the channel you identified in Step 1:

```bash
cat <<EOF | oc apply -f -
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
EOF
```

`installPlanApproval: Automatic` means OLM will approve and execute the install without you having to manually approve an `InstallPlan`. Use `Manual` if you want to inspect what will be installed before committing — useful in production environments where you want to control when upgrades happen.

Once the Subscription is applied, OLM creates an `InstallPlan` and begins pulling the operator. You can watch its progress:

```bash
oc get installplan -n openshift-logging
```

```
NAME            CSV                       APPROVAL    APPROVED
install-abc12   cluster-logging.v6.5.0    Automatic   true
```

---

### Step 4: Wait for the CSV, Not Just the Pod

After applying a Subscription, the OLM installs the operator as a `ClusterServiceVersion`. The CSV is the real indicator of a successful install — a pod being `Running` just means the container started, not that OLM finished reconciling.

```bash
oc get csv -n openshift-logging -w
```

```
NAME                       DISPLAY                     VERSION   PHASE
cluster-logging.v6.5.0     Red Hat OpenShift Logging   6.5.0     Installing
cluster-logging.v6.5.0     Red Hat OpenShift Logging   6.5.0     Succeeded
```

Don't apply CRs until the CSV reaches `Succeeded`. If it stalls at `Installing`, check `oc get installplan -n <namespace>` for approval blocks or dependency resolution failures.

---

### Step 5: Find What CRDs the Operator Registered

Once the CSV is `Succeeded`, the operator has registered its CRDs into the cluster API. Don't assume you know their names or API groups — operators change these across major versions. In Logging's case, 5.x used `logging.openshift.io` and 6.x moved to `observability.openshift.io`.

The most reliable way to see exactly what the operator registered is to ask the CSV directly. It has an explicit `owned` list of every CRD it manages:

```bash
oc get csv cluster-logging.v6.5.0 -n openshift-logging \
  -o jsonpath='{range .spec.customresourcedefinitions.owned[*]}{.name}{"\t"}{.version}{"\t"}{.kind}{"\n"}{end}'
```

```
clusterlogforwarders.observability.openshift.io   v1   ClusterLogForwarder
logfilemetricexporters.logging.openshift.io       v1alpha1   LogFileMetricExporter
```

This is authoritative — it's the same list OLM used to register the CRDs, so it works even when the API group name has nothing obvious to do with the operator. If you don't know the exact CSV name, grab it first:

```bash
oc get csv -n openshift-logging -o name
```

If you want a quick scan across all CRDs on the cluster without knowing the CSV name, grep is a useful secondary option:

```bash
oc get crd | grep -E "logging|observ"
```

```
clusterlogforwarders.observability.openshift.io   2026-04-01T20:03:34Z
logfilemetricexporters.logging.openshift.io       2026-04-01T20:03:34Z
```

Either way, this tells you two things immediately: the API group changed, and `ClusterLogging` is gone entirely in this version. If you'd written `apiVersion: logging.openshift.io/v1` in your manifest, it would have been rejected.

---

### Step 6: Explore the Spec with `oc explain`

`oc explain` is the most underused tool for working with operators. It reads the CRD's API schema and prints field descriptions, types, and required markers directly in your terminal. You don't need docs, you don't need examples — you can walk the entire spec yourself.

Start at the top level:

```bash
oc explain clusterlogforwarders.observability.openshift.io.spec
```

Go deeper with `--recursive` to see the full tree:

```bash
oc explain clusterlogforwarders.observability.openshift.io.spec --recursive
```

Drill into a specific sub-field to get descriptions and enum values:

```bash
oc explain clusterlogforwarders.observability.openshift.io.spec.outputs.syslog
```

```
FIELDS:
  appName     <string>
  enrichment  <string>
  enum: None, KubernetesMinimal
  facility    <string>
  msgId       <string>
  payloadKey  <string>
  procId      <string>
  rfc         <string> -required-
  enum: RFC3164, RFC5424
  severity    <string>
  tuning      <Object>
    deliveryMode  <string>
    enum: AtLeastOnce, AtMostOnce
  url         <string> -required-
```

The `-required-` markers tell you exactly which fields you can't skip. The `enum:` lines tell you the valid values. This is more reliable than docs for the version actually installed on your cluster.

Use the same approach to discover the `serviceAccount` requirement — something that often isn't obvious until you get a validation error:

```bash
oc explain clusterlogforwarders.observability.openshift.io.spec.serviceAccount
```

```
FIELDS:
  name  <string> -required-
```

And to understand how the v6 input filtering changed from `application.namespaces` to `application.includes`:

```bash
oc explain clusterlogforwarders.observability.openshift.io.spec.inputs.application --recursive
```

```
FIELDS:
  excludes  <[]Object>
    container   <string>
    namespace   <string>
  includes  <[]Object>
    container   <string>
    namespace   <string>
  ...
```

If you prefer a visual interface, the OpenShift web console has an API Explorer under **Home → API Explorer**. Search for the resource by kind, select it, and the Schema tab gives you the same field tree with descriptions — useful for browsing without constructing `oc explain` paths by hand.

---

## Putting It Together

The pattern here applies to any operator, not just Logging:

1. `oc get packagemanifest -n openshift-marketplace | grep <keyword>` — find available operators and which catalog they come from
2. `oc get packagemanifest <name>` — find channels and the default before subscribing
3. Apply a `Namespace`, `OperatorGroup`, and `Subscription` — the three resources OLM needs to install the operator
4. `oc get csv -n <namespace> -w` — wait for `Succeeded`, not just a running pod
5. `oc get csv <name> -o jsonpath='{range .spec.customresourcedefinitions.owned[*]}{.name}{"\n"}{end}'` — confirm the exact CRDs the operator registered
6. `oc explain <crd>.spec --recursive` — walk the full spec without leaving the terminal

None of this requires external access or docs that match your exact version. Everything you need is already in the cluster.

---

## References

- [OCP Docs: Adding operators to a cluster](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/operators/administrator-tasks#olm-adding-operators-to-a-cluster)
- [OCP Docs: oc explain](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/cli_tools/openshift-cli-oc#oc-explain)
- [Kubernetes Docs: Understanding CRD validation schemas](https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#validation)
