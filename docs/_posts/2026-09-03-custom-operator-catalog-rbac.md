---
layout: post
title: "Building a Custom Operator Catalog"
date: 2026-09-03
---

*Part 1 of 4 in a series on curating and distributing OpenShift catalogs: **Building a Custom Operator Catalog** · [Restricting Operator Installs with RBAC](/2026/09/03/operator-install-rbac.html) · [Curating the OpenShift Software Catalog](/2026/09/03/curating-the-software-catalog.html) · [Distributing Custom Operator and Software Catalogs with ACM Policies](/2026/09/03/distributing-custom-catalogs-with-acm.html)*

OpenShift ships with four default operator catalogs: Red Hat, Certified, Community, and Marketplace. These contain well over a hundred distinct operators. Any user with sufficient privileges can browse and install from all of them. In an enterprise environment, that is too much surface area. You want to decide which operators are available before worrying about who gets to install them. This is a quick why and how-to for building a curated operator catalog and disabling the defaults.

## Why This Matters

Every operator installed on a cluster is a controller running with elevated privileges. It registers CRDs into the cluster API, runs reconciliation loops, and often installs webhooks that intercept API requests for its managed resources. Some operators require cluster-admin equivalent permissions to function. None of that is inherently bad, it is what operators are designed to do, but each one adds surface area that needs to be understood, maintained, and secured.

The default catalogs make all of this available to anyone who can create a Subscription. On a cluster with default RBAC, that includes anyone with `edit` or `admin` in any namespace that has an OperatorGroup. A developer investigating a messaging solution can install AMQ Streams, Strimzi, and three community Kafka operators in the same afternoon, each one registering cluster-scoped CRDs and running controllers. Nobody reviewed whether those operators are compatible with each other, whether they have been tested against the current cluster version, or whether the security team has approved their use.

The fix is to replace the default catalogs with a curated catalog that contains only the operators your organization has vetted. This limits what is available: no one can install an operator that is not in the catalog, regardless of their RBAC. A curated catalog decides what is possible in the first place, which is a different and more foundational control than deciding who is allowed to act.

A curated catalog on its own still lets any user with namespace access install anything in it, RBAC is what decides who gets to act on that catalog, and it is worth layering on top once the catalog itself is in place. That is covered separately in [Restricting Operator Installs with RBAC](/2026/09/03/operator-install-rbac.html).

---

## The Steps

1. Disable the default OperatorHub catalog sources
2. Install `opm` and check your cluster version
3. Decide which operators to include in the curated catalog
4. Extract the full Red Hat catalog and verify operator dependencies
5. Build and validate the curated catalog
6. Build and push the catalog container image to the internal registry
7. Deploy a custom CatalogSource on the cluster

---

## How To Do It

This walkthrough assumes you have cluster-admin access to an OpenShift 4.20+ cluster and `podman` installed on your workstation. The `opm` CLI is used for building the catalog. Installation instructions are included in Step 2 if needed.

### Step 1: Disable the Default Catalog Sources

OpenShift's OperatorHub is backed by four CatalogSource resources in the `openshift-marketplace` namespace. Before adding a custom catalog, we will disable the defaults so that only the curated operators are visible. This does not uninstall any operators that are already running. Their Subscriptions and CSVs remain intact, it only prevents new installations from these catalogs.

First, check what catalog sources currently exist:

```bash
oc get catalogsource -n openshift-marketplace
```

```
NAME                  DISPLAY               TYPE   PUBLISHER   AGE
certified-operators   Certified Operators   grpc   Red Hat     30d
community-operators   Community Operators   grpc   Red Hat     30d
redhat-marketplace    Red Hat Marketplace   grpc   Red Hat     30d
redhat-operators      Red Hat Operators      grpc   Red Hat     30d
```

Download [1-disable-default-catalogs.yaml](/posts/custom-operator-catalog-rbac/1-disable-default-catalogs.yaml) and apply it:

```bash
oc apply -f 1-disable-default-catalogs.yaml
```

This resource is the cluster-scoped `OperatorHub` object named `cluster`. The `spec.sources` array lists each of the four default catalogs by name with `disabled: true`. When OLM sees a source marked as disabled, it removes the corresponding CatalogSource from `openshift-marketplace` and all PackageManifests from that source disappear.

Verify the default catalogs are gone:

```bash
oc get catalogsource -n openshift-marketplace
```

```
No resources found in openshift-marketplace namespace.
```

Confirm that no operators appear in OperatorHub:

```bash
oc get packagemanifest -n openshift-marketplace
```

```
No resources found in openshift-marketplace namespace.
```

The cluster now has no operator catalogs. Existing operators continue to run, but no new operators can be installed until you deploy a replacement catalog.

---

### Step 2: Install `opm` and Check Your Cluster Version

A file-based catalog (FBC) is the current standard for OLM operator catalogs. It replaces the older SQLite database format with a directory of JSON or YAML files that describe packages, channels, and bundles. The `opm` CLI renders operators from an upstream index image into this format, and you will use it again in Step 4 to pull that index image.

Both `opm` and the index image are versioned per OpenShift release, so check your cluster's version once now and use it consistently for both:

```bash
oc get clusterversion -o jsonpath='{.items[0].status.desired.version}'
```

The examples below use `v4.22`, the version this walkthrough was tested against, so substitute your own throughout.

Download the `opm` binary from the OpenShift mirror, matching the cluster version you just checked:

```bash
curl -Lo opm https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable-4.22/opm-linux.tar.gz
tar xzf opm-linux.tar.gz
chmod +x opm
sudo mv opm /usr/local/bin/
```

Verify the installation:

```bash
opm version
```

---

### Step 3: Decide Which Operators to Include

The curated catalog in this walkthrough includes thirty-four operators, drawn from two of the four default sources: the Red Hat Operators catalog for the bulk of the list, and the Certified Operators catalog for a couple of vendor-certified additions. The first priority is including every operator that already has an active Subscription on the cluster. If an existing operator is not in the new catalog OLM cannot resolve updates for it. After that, the list includes additional developer and admin operators the organization wants to make available. Adjust this list to match what your organization has reviewed and approved.

**Example currently installed operators (must be included):**

| Operator | Purpose |
|----------|---------|
| netobserv-operator | Network observability (eBPF flow collection) |
| loki-operator | Log and flow storage backend |
| openshift-cert-manager-operator | TLS certificate management |
| rhbk-operator | Red Hat build of Keycloak (SSO) |
| odf-operator | OpenShift Data Foundation storage |

**ODF dependency operators (auto-managed, but must be present for update resolution):**

| Operator | Purpose |
|----------|---------|
| cephcsi-operator | Ceph CSI driver |
| mcg-operator | Multi-Cloud Gateway (NooBaa) |
| ocs-client-operator | OCS client |
| ocs-operator | OpenShift Container Storage |
| odf-csi-addons-operator | CSI add-ons |
| odf-dependencies | ODF shared dependencies |
| odf-external-snapshotter-operator | Volume snapshot controller |
| odf-prometheus-operator | ODF monitoring |
| ocs-tls-profiles | Shared TLS security profile config for ODF components |
| recipe | ODF disaster recovery recipes |
| rook-ceph-operator | Rook-Ceph storage orchestration |

**Additional curated operators:**

| Operator | Audience | Purpose |
|----------|----------|---------|
| openshift-pipelines-operator-rh | Developer | CI/CD pipelines (Tekton) |
| openshift-gitops-operator | Developer | GitOps with ArgoCD |
| amq-streams | Developer | Apache Kafka messaging |
| amq-broker-rhel8 | Developer | ActiveMQ messaging |
| serverless-operator | Developer | Knative serverless workloads |
| rh-service-binding-operator | Developer | Bind services to applications |
| web-terminal | Developer | Browser-based terminal |
| devworkspace-operator | Developer | Cloud development workspaces |
| quay-operator | Both | Container image registry |
| cluster-logging | Admin | Cluster log collection |
| compliance-operator | Admin | Compliance scanning |
| file-integrity-operator | Admin | File integrity monitoring |
| rhacs-operator | Admin | Advanced Cluster Security |
| local-storage-operator | Admin | Local disk management |
| nfd | Admin | Node feature discovery |
| costmanagement-metrics-operator | Admin | Cost management reporting |

**Certified operators (from the Certified catalog, not Red Hat Operators):**

| Operator | Audience | Purpose |
|----------|----------|---------|
| crunchy-postgres-operator | Developer | PostgreSQL database, Crunchy Data's certified operator |
| datadog-operator | Admin | Datadog observability agent and integration |

Everything above this table comes from the Red Hat Operators index. These last two come from the separate Certified Operators index, which Step 4 extracts independently before merging both into one curated catalog.

Treat this list as a first draft. Step 4 shows how to verify it against the real catalog data before you commit to it.

---

### Step 4: Extract the Catalog and Verify Dependencies

This walkthrough draws its curated catalog from two of the four default sources: Red Hat Operators for the bulk of the list, and Certified Operators for a couple of vendor-certified additions. The same extract-and-copy process works against Community or Marketplace as well if your organization needs operators from either of those: only the index image reference changes. Step 1 disables all four default sources regardless, since the goal is to replace OperatorHub entirely with a single curated source, not just carve out a slice of it.

The Red Hat operator index image contains the full file-based catalog organized as one directory per operator package. The most reliable way to build a curated catalog is to extract the full catalog from the index image, then copy only the packages you want into a new directory. This avoids rendering issues and gives you the exact catalog data that Red Hat ships.

Authenticate to `registry.redhat.io` before pulling the index image; you can use the cluster's pull secret if you do not have individual credentials:

```bash
oc get secret/pull-secret -n openshift-config \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > cluster-pull-secret.json

podman login --authfile cluster-pull-secret.json registry.redhat.io
```

Pulling the index image only downloads it; it does not, by itself, give you access to what is inside. The index image is not meant to run as a container; it is a filesystem image with the file-based catalog baked in at `/configs`. To get that directory onto your local disk, pull the image using the same version you checked in Step 2, create a container from it without starting it, copy `/configs` out with `podman cp`, then remove the container since you do not need it running:

```bash
podman pull --platform linux/amd64 --authfile cluster-pull-secret.json \
  registry.redhat.io/redhat/redhat-operator-index:v4.22

podman create --platform linux/amd64 --name temp-idx registry.redhat.io/redhat/redhat-operator-index:v4.22
podman cp temp-idx:/configs full-catalog
podman rm temp-idx
```

Pulling a mismatched version here gives you a catalog of operators built for a different minor version than the one you are running; the same substitution rule from the `opm` download in Step 2 applies.

The `--platform linux/amd64` flag matters here for the same reason it matters later when building the catalog image: if you are working from an Apple Silicon or other non-x86 workstation, `podman pull` and `podman create` default to your local architecture, and the Red Hat index image is not published for every architecture. Without the flag, you may pull the wrong variant or fail outright depending on what is available.

Step 3's two Certified operators live in a separate index image, `certified-operator-index`, not `redhat-operator-index`. Red Hat separates its catalogs by certification tier rather than by registry, so the certified index is hosted at the same `registry.redhat.io` and works with the same pull secret already authenticated above. Extract it the same way, into its own directory so it does not overwrite the Red Hat extraction:

```bash
podman pull --platform linux/amd64 --authfile cluster-pull-secret.json \
  registry.redhat.io/redhat/certified-operator-index:v4.22

podman create --platform linux/amd64 --name temp-idx-certified registry.redhat.io/redhat/certified-operator-index:v4.22
podman cp temp-idx-certified:/configs full-catalog-certified
podman rm temp-idx-certified
```

Combining two independently maintained catalogs into one raises a question neither one answers on its own: OLM identifies a package by name only, it has no concept of which catalog that name came from, so if the same package name happened to exist in both indexes, whichever one you copied last into the curated catalog would silently win. Check for collisions before going further:

```bash
comm -12 <(ls full-catalog | sort) <(ls full-catalog-certified | sort)
```

`comm -12` compares two sorted lists and prints only the lines common to both. For this walkthrough's picks the output should be empty; if it is not, do not proceed until you have either dropped one of the colliding packages from your list or confirmed which catalog actually publishes the operator you intended.

The `full-catalog` directory now contains one subdirectory per operator package. The internal layout varies by package: some contain a single `catalog.json` with every package, channel, and bundle entry inlined, others split the same information across a `package.json` plus separate `bundles/` and `channels/` directories. Both are valid FBC; the build script in Step 5 copies whichever layout a package uses without caring which one it is. You can list all available packages:

```bash
ls full-catalog/
```

This shows every operator in the Red Hat catalog. Operator catalogs are living things: packages get renamed, deprecated, or dropped between index versions, so treat this list as a snapshot rather than a permanent reference. Before finalizing the list you drafted in Step 3, it is worth checking whether any of your candidates has undeclared dependencies it is missing. Some operators, like ODF's top-level `odf-operator`, install their sub-components programmatically and declare no formal OLM dependencies at all; static inspection tells you nothing about those, and the only reliable way to catch them is to already know the product's architecture or watch what Subscriptions it creates on a test cluster. Other packages, like `odf-dependencies`, do declare formal dependencies through the standard `olm.package.required` and `olm.gvk.required` bundle properties, and those you can check directly.

The most reliable way to check is to serve the extracted catalog locally with `opm` and query it the same way OLM itself does, over its gRPC API, using [grpcurl](https://github.com/fullstorydev/grpcurl):

```bash
opm serve full-catalog --port 50051 &
```

`opm serve` parses every file under `full-catalog/` as catalog data, it does not filter by extension. If a file manager ever browsed that directory, check for OS-added files like macOS's `.DS_Store` first; those are binary, not FBC data, and will fail with an error like `error converting YAML to JSON: yaml: control characters are not allowed`:

```bash
find full-catalog -name ".DS_Store" -delete
```

```bash
grpcurl -plaintext -d '{"pkgName":"odf-dependencies","channelName":"stable-4.22"}' \
  localhost:50051 api.Registry/GetBundleForChannel | jq '.dependencies'
```

```json
[
  { "type": "olm.package", "value": "{\"packageName\":\"cephcsi-operator\",\"version\":\"4.22.2-rhodf\"}" },
  { "type": "olm.package", "value": "{\"packageName\":\"ocs-tls-profiles\",\"version\":\"4.22.2-rhodf\"}" }
]
```

This is exactly how the `ocs-tls-profiles` row in Step 3's ODF dependency table was found: it does not have an active Subscription of its own on most clusters, so it would never surface from "check what is currently installed" alone, but `odf-dependencies` formally requires it. Skipping it would not break anything today, since none of these clusters install ODF fresh against this catalog, but it would cause a real resolution failure the first time someone did. Run this check against any package before you commit to a final operator list, then stop the local server:

```bash
kill %1
```

The same `opm serve` plus `grpcurl` check works against `full-catalog-certified` too: point `opm serve` at that directory instead, on a different port, if you need to verify a Certified package's dependencies the same way.

---

### Step 5: Build and Validate the Curated Catalog

With Step 3's list confirmed against the real catalog data, copy only the packages you want into a new directory, from both `full-catalog` and `full-catalog-certified`. The build script automates this. Download [2-build-catalog.sh](/posts/custom-operator-catalog-rbac/2-build-catalog.sh):

```bash
chmod +x 2-build-catalog.sh
./2-build-catalog.sh
```

The script does four things. First, `set -euo pipefail` makes the script exit immediately on any command failure, unset variable, or failed step in a pipeline; this is standard defensive practice for a script that is about to loop over thirty-plus copy operations, since a silent partial failure here would produce a catalog missing operators with no obvious error. Second, the `OPERATORS` array lists every Red Hat catalog package to include, grouped with comments matching the tables in Step 3: currently-installed operators, ODF dependencies, developer-facing, shared, and admin-facing; a separate `CERTIFIED_OPERATORS` array lists the two Certified catalog packages. Third, a `copy_operators` function loops over an array and, for each name, copies `<source_dir>/<operator>` into `custom-catalog/<operator>` if it exists, or prints `MISSING` and keeps a count if it does not; this catches typos in the operator list or cases where a package name changed in the index without failing the whole build. The script calls this function once for `full-catalog`/`OPERATORS` and once for `full-catalog-certified`/`CERTIFIED_OPERATORS`, so both catalogs land in the same `custom-catalog` directory. Fourth, it runs `opm validate custom-catalog` against the assembled directory. Validation checks that the catalog structure is well-formed: valid JSON, no missing channel references, no dangling bundle dependencies. If validation fails, the output tells you which operator has a problem.

If any operators are reported `MISSING`, check the exact package name against the index: run `ls full-catalog/ | grep <partial-name>` to find the correct name and update the `OPERATORS` array in the script.

Verify the catalog contains the expected operators:

```bash
ls -d custom-catalog/*/ | wc -l
```

```
34
```

Each directory represents one operator package. Thirty-four directories means all operators, from both catalogs, were copied successfully.

---

### Step 6: Build and Push the Catalog Image

The catalog needs to be packaged as a container image that OLM can pull and serve. The image uses the `ose-operator-registry` base image, which includes the `opm serve` binary that OLM uses to query the catalog over gRPC.

Download [3-catalog.Containerfile](/posts/custom-operator-catalog-rbac/3-catalog.Containerfile) and review it:

The `FROM` line uses `registry.redhat.io/openshift4/ose-operator-registry-rhel9`, the official Red Hat base image for file-based catalogs, tagged to match your cluster's minor version the same way the index image was in Step 4; a mismatched tag means a different `opm` binary than the one your cluster's OLM expects to talk to. It includes the `opm` binary that serves the catalog to OLM. The `COPY` instruction places the catalog files into `/configs` inside the image. The `RUN` line pre-builds the serving cache: this is an optimization that speeds up CatalogSource startup by building the gRPC serving index at image build time rather than at container start time. The `ENTRYPOINT` and `CMD` configure the container to run `opm serve` against the `/configs` directory when started.

**Build the image:**

The `--platform linux/amd64` flag ensures the image is built for the cluster's architecture. If you are building on an x86_64 Linux workstation, you can omit this flag. On Apple Silicon or other non-x86 systems, it is required; without it, the catalog pod will fail with `Exec format error` on the cluster.

```bash
podman build --platform linux/amd64 \
  --authfile cluster-pull-secret.json \
  -f 3-catalog.Containerfile -t curated-operator-catalog:v4.22.10 .
```

**Push to the internal OpenShift registry:**

The internal registry needs to be exposed via a route for external pushes. Check if the route exists:

```bash
oc get route default-route -n openshift-image-registry
```

If no route exists, create one:

```bash
oc patch configs.imageregistry.operator.openshift.io/cluster \
  --type merge \
  --patch '{"spec":{"defaultRoute":true}}'
```

Get the registry hostname and log in:

```bash
REGISTRY=$(oc get route default-route -n openshift-image-registry \
  -o jsonpath='{.spec.host}')

podman login --tls-verify=false -u $(oc whoami) -p $(oc whoami -t) ${REGISTRY}
```

The `--tls-verify=false` flag is needed because the default route uses the cluster's internal CA certificate, which your workstation does not trust by default. In a production environment, you would add the cluster's CA to your local trust store instead.

Tag and push the image:

```bash
podman tag curated-operator-catalog:v4.22.10 \
  ${REGISTRY}/openshift-marketplace/curated-operator-catalog:v4.22.10

podman push --tls-verify=false \
  ${REGISTRY}/openshift-marketplace/curated-operator-catalog:v4.22.10
```

Verify the image stream was created:

```bash
oc get imagestream curated-operator-catalog -n openshift-marketplace
```

```
NAME                         IMAGE REPOSITORY                                                                          TAGS     UPDATED
curated-operator-catalog     image-registry.openshift-image-registry.svc:5000/openshift-marketplace/curated-operator-catalog   v4.22.10    5s ago
```

---

### Step 7: Deploy the Custom CatalogSource

With the image in the internal registry, create a CatalogSource that tells OLM where to find the curated catalog.

Download [4-custom-catalogsource.yaml](/posts/custom-operator-catalog-rbac/4-custom-catalogsource.yaml) and apply it:

```bash
oc apply -f 4-custom-catalogsource.yaml
```

The CatalogSource resource tells OLM to pull the catalog image and start a gRPC server that serves the catalog contents. `sourceType: grpc` indicates the image runs an OPM serve process. The `image` field points to the internal registry using the in-cluster service address (`image-registry.openshift-image-registry.svc:5000`), not the external route: pods within the cluster resolve this address directly without needing the route. The `displayName` and `publisher` fields appear in the OperatorHub UI. The `updateStrategy` with `registryPoll.interval: 30m` tells OLM to check the image tag for updates every thirty minutes, so when you push a new version of the catalog image, OLM picks it up automatically without restarting anything.

Wait for the catalog source pod to become ready:

```bash
oc get pods -n openshift-marketplace -l olm.catalogSource=curated-operators
```

```
NAME                        READY   STATUS    RESTARTS   AGE
curated-operators-abc12     1/1     Running   0          30s
```

**If you see more than one pod under that label,** do not treat it as normal churn. The pre-built cache from Step 6 combined with a tight startup probe can cause the catalog-operator to spin up a replacement pod before the first one finishes coming ready, and it does not always clean up the earlier pod once it does become healthy; you end up with several `Running`, `1/1` pods accumulating over time instead of one. Delete them all and let the operator recreate a single clean one:

```bash
oc delete pods -n openshift-marketplace -l olm.catalogSource=curated-operators
```

Wait about a minute and check again: you should see exactly one pod this time, and it should reach `1/1` without spawning a replacement.

Verify that only the curated operators appear as available packages:

```bash
oc get packagemanifest -n openshift-marketplace
```

You should see exactly thirty-four operators, all from the `curated-operators` source. If you see operators from other sources, check that Step 1 completed correctly.

If you browse the catalog in the OpenShift console instead of the CLI, do not be surprised to see fewer than thirty-four tiles. The console's catalog view deliberately hides any package whose CSV is annotated `operators.operatorframework.io/operator-type: non-standalone`, a convention operator authors use to mark components that are meant to be pulled in as a dependency rather than installed directly. Several of the ODF packages in this catalog carry that annotation, so they exist and resolve correctly but never appear as a browsable tile. `oc get packagemanifest` is not affected by this filter and always reflects the full count.

Confirm a specific operator is available with its expected channels:

```bash
oc get packagemanifest openshift-pipelines-operator-rh -n openshift-marketplace \
  -o jsonpath='{.status.channels[*].name}'
```

The output should show the channels that existed in the Red Hat index at the time you built the catalog.

**Repoint existing Subscriptions to the new catalog**

If this cluster already had operators installed before you started this walkthrough, this step is not optional. Skip it and every one of those Subscriptions keeps referencing a CatalogSource that no longer exists: OLM stops resolving updates for them, silently, with no error surfaced anywhere you would naturally look.

A Subscription's `spec.source` field is set once, at creation time, and is never automatically migrated when you switch catalogs. Find every Subscription still pointing at a now-disabled default source:

```bash
oc get subscriptions.operators.coreos.com -A \
  -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,SOURCE:.spec.source \
  | grep -E 'redhat-operators|certified-operators|community-operators|redhat-marketplace'
```

Each one is already showing a real, visible symptom now that its old source is gone. Check the conditions on any Subscription from that list:

```bash
oc get subscription <subscription-name> -n <namespace> -o jsonpath='{.status.conditions}'
```

```json
[
  {
    "type": "CatalogSourcesUnhealthy",
    "status": "True",
    "reason": "UnhealthyCatalogSourceFound",
    "message": "targeted catalogsource openshift-marketplace/redhat-operators missing"
  },
  {
    "type": "ResolutionFailed",
    "status": "True",
    "reason": "ConstraintsNotSatisfiable",
    "message": "constraints not satisfiable: no operators found from catalog redhat-operators in namespace openshift-marketplace referenced by subscription <subscription-name>, subscription <subscription-name> exists"
  }
]
```

The operator itself keeps running fine (`status.installedCSV` is untouched by any of this), but OLM cannot resolve any future update until the Subscription points at a source that actually exists. Patch each one:

```bash
oc patch subscription <subscription-name> -n <namespace> \
  --type merge \
  --patch '{"spec":{"source":"curated-operators"}}'
```

If any of these Subscriptions use `installPlanApproval: Automatic`, check `spec.channel` against the channel head in your new catalog before patching: if your curated catalog is ahead of what is currently installed, repointing the source can trigger an immediate, unattended upgrade rather than just resuming update resolution.

Confirm the condition clears:

```bash
oc get subscription <subscription-name> -n <namespace> -o jsonpath='{.status.conditions}'
```

```json
[{"type":"CatalogSourcesUnhealthy","status":"False","reason":"AllCatalogSourcesHealthy","message":"all available catalogsources are healthy"}]
```

The curated catalog now limits what operators are discoverable and installable to the 34 you chose, drawn from the Red Hat and Certified catalogs. By itself it still lets any user with namespace access install anything in it. Layering RBAC on top, so cluster-wide installs are limited to platform administrators and everyone else is scoped to their own namespace, is covered in a follow-up post: [Restricting Operator Installs with RBAC](/2026/09/03/operator-install-rbac.html).

---

## What You Built

| Layer | What It Controls | How It Works |
|-------|-----------------|--------------|
| OperatorHub disabled | Which catalogs exist | Removes default Red Hat, Certified, Community, and Marketplace sources |
| Custom CatalogSource | Which operators are available | Only the 34 curated operators, from the Red Hat and Certified catalogs, can be discovered or installed |

Updating the catalog with newer operator versions from the same OpenShift release is a matter of rebuilding and re-pushing to the same `v4.22.10` tag; the CatalogSource's `registryPoll` picks up the new digest within thirty minutes, no other changes needed. Moving to a new OpenShift minor version is different: rebuild against that version's index image, push under its own tag (`v4.23.0`, and so on), and update the CatalogSource's `image` field to point at it, since the tag is now tied to a specific release rather than floating.

Two natural next steps from here: [Restricting Operator Installs with RBAC](/2026/09/03/operator-install-rbac.html) controls who can install from this catalog and where, and if you manage multiple clusters, [Distributing Custom Operator and Software Catalogs with ACM Policies](/2026/09/03/distributing-custom-catalogs-with-acm.html) covers getting the same catalog onto every managed cluster automatically.

---

## References

- [OCP Docs: Managing custom catalogs](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/operators/administrator-tasks#olm-managing-custom-catalogs)
- [OCP Docs: File-based catalogs](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/operators/understanding-operators#olm-file-based-catalogs_olm-packaging-format)
- [OCP Docs: Exposing the registry](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/registry/securing-exposing-registry)
- [grpcurl](https://github.com/fullstorydev/grpcurl)
- [How to Find, Install, and Explore an OpenShift Operator from the CLI](/2026/04/06/exploring-openshift-operators.html)
- [Restricting Operator Installs with RBAC](/2026/09/03/operator-install-rbac.html)
