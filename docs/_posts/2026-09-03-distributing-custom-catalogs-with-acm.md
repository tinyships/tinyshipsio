---
layout: post
title: "Distributing Custom Operator and Software Catalogs with ACM Policies"
date: 2026-09-03
---

*Part 4 of 4 in a series on curating and distributing OpenShift catalogs: [Building a Custom Operator Catalog](/2026/09/03/custom-operator-catalog-rbac.html) · [Restricting Operator Installs with RBAC](/2026/09/03/operator-install-rbac.html) · [Curating the OpenShift Software Catalog](/2026/09/03/curating-the-software-catalog.html) · **Distributing Custom Operator and Software Catalogs with ACM Policies***

You have a curated operator catalog and a curated software catalog running on one cluster. That is a solved problem for a single cluster, but most organizations run more than one. Manually replicating the same catalog configuration across every cluster is the kind of work that stays consistent for about a week before someone misses one. Red Hat Advanced Cluster Management for Kubernetes (ACM) has a policy framework that makes this declarative: you define what should exist, which clusters it applies to, and ACM enforces it continuously. This is a quick why and how-to for distributing your custom operator catalog and your curated software catalog settings across every managed cluster using ACM policies.

## Why This Matters

A curated catalog is only as good as its weakest cluster. If you built one by hand on one cluster following [Building a Custom Operator Catalog](/2026/09/03/custom-operator-catalog-rbac.html) and [Curating the OpenShift Software Catalog](/2026/09/03/curating-the-software-catalog.html), you now have a checklist: disable four catalog sources, push an image, apply a CatalogSource, disable the default Helm chart repository, skip and delete sample Templates, restrict which content types the console shows. Running that checklist again on a second cluster is tedious but doable. Running it correctly on the fifteenth cluster, six months from now, when someone new joins the platform team and has never seen the checklist, is where it falls apart. A step gets skipped, a typo changes a value, a cluster gets rebuilt and quietly reverts to the defaults. Nobody notices until an audit or an incident surfaces it.

The deeper problem is not the initial setup: it is drift. Even a cluster configured perfectly on day one degrades over time. Someone re-enables the default Helm chart repository while troubleshooting a chart issue and forgets to turn it back off. A cluster gets rebuilt and comes back with all 127 sample Templates nobody meant to ship. A new cluster gets imported into the fleet and never receives any of this configuration because onboarding a cluster and onboarding it to the catalog policies are two different, disconnected checklists. None of this shows up as an error. It shows up as inconsistency: cluster three behaves differently from cluster seven, and nobody can say why without comparing them resource by resource.

ACM's policy framework treats this as a continuous reconciliation problem instead of a one-time setup task. You declare the desired state once, on the hub cluster, and a controller running on every managed cluster checks that state against reality on a loop, by default every few minutes, and immediately whenever it detects drift. If a resource is missing, it is created. If a resource has drifted from the declared spec, it is corrected. If a new cluster joins the fleet, it inherits every policy the moment it is placed, with zero manual steps. The compliance state of every cluster is visible from one dashboard on the hub, so "is cluster seven configured correctly" becomes a query instead of an investigation.

## The Steps

1. Create a policy namespace and Placement on the ACM hub cluster
2. Deploy a policy to disable default catalog sources on all managed clusters
3. Deploy a policy to distribute Quay pull credentials for the catalog image
4. Deploy a policy to create the custom CatalogSource on all managed clusters
5. Deploy a policy to disable the default Helm chart repository fleet-wide
6. Deploy a policy to curate sample Templates fleet-wide
7. Deploy a policy to restrict console content types fleet-wide
8. Validate compliance across managed clusters and confirm drift reconciliation

## How To Do It

This walkthrough assumes ACM is installed on your hub cluster and at least one managed cluster is imported. If you have not set that up yet, the [ACM installation documentation](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html/install/installing) covers the operator installation and cluster import process. It builds on the resources created in [Building a Custom Operator Catalog](/2026/09/03/custom-operator-catalog-rbac.html) and [Curating the OpenShift Software Catalog](/2026/09/03/curating-the-software-catalog.html), the same OperatorHub configuration, CatalogSource, and software catalog manifests are wrapped in ACM ConfigurationPolicies for fleet-wide distribution. You do not need to have completed those posts first; every resource is explained here as it is introduced. All commands run against the hub cluster unless noted otherwise.

### Step 1: Create the Policy Namespace and Placement

ACM policies, Placements, and PlacementBindings are standard Kubernetes resources that live on the hub cluster, grouped in a dedicated namespace to keep them separate from workloads. If you already created this namespace while following [Automatic RBAC for New Namespaces with Advanced Cluster Management Policies](/2026/05/17/acm-namespace-rbac-policies.html), this step is a no-op: the resource names match on purpose, and `oc apply` is idempotent.

Download [1-policy-namespace.yaml](/posts/distributing-custom-catalogs-with-acm/1-policy-namespace.yaml) and apply it:

```bash
oc apply -f 1-policy-namespace.yaml
```

The file contains three resources. The `Namespace` creates `acm-policies` where every policy in this walkthrough will live. The `ManagedClusterSetBinding` binds the `global` ManagedClusterSet, which ACM ships pre-populated with every managed cluster, to this namespace. A Placement can only select clusters from sets bound to its own namespace, so without this binding a Placement here would resolve to zero clusters. The `Placement` named `all-managed-clusters` is what policies reference to decide where they get distributed. An empty `labelSelector` with no `matchExpressions` matches every cluster in the bound set, which because you bound `global` means every managed cluster in the fleet. To scope this to a subset instead, staging clusters only for example, add a `matchLabels` entry here.

Verify the Placement resolved your managed clusters:

```bash
oc get placement all-managed-clusters -n acm-policies
```

```
NAME                   SUCCEEDED   REASON                  SELECTEDCLUSTERS
all-managed-clusters   True        AllDecisionsScheduled   1
```

If `SELECTEDCLUSTERS` shows `0`, check that the ManagedClusterSetBinding applied correctly and that at least one cluster is imported into ACM.

### Step 2: Disable Default Catalogs on Every Managed Cluster

The first layer of the curated catalog is removing the default OperatorHub sources: Red Hat, Certified, Community, and Marketplace, so that only vetted operators are discoverable. Locally this is a single `oc apply` of an `OperatorHub` resource. Distributed across a fleet, it needs to be a policy so a cluster that gets rebuilt, or a source that gets manually re-enabled, is brought back into line automatically.

Download [2-policy-disable-default-catalogs.yaml](/posts/distributing-custom-catalogs-with-acm/2-policy-disable-default-catalogs.yaml) and apply it:

```bash
oc apply -f 2-policy-disable-default-catalogs.yaml
```

The file defines a `Policy`, a `ConfigurationPolicy` nested inside it, and a `PlacementBinding`. `remediationAction: enforce` on the `Policy` tells ACM to actively create or correct resources rather than only reporting on them; with `inform` instead, ACM would flag non-compliant clusters without touching them. Inside `policy-templates`, the `ConfigurationPolicy`'s single `object-templates` entry wraps the exact `OperatorHub`/`cluster` object from the catalog post, with `complianceType: musthave` meaning ACM creates it if missing and corrects the `spec.sources` list if someone changes it. There is no `namespaceSelector` here because `OperatorHub` is a cluster-scoped resource, not a namespaced one: the object applies once per managed cluster, not once per namespace. The `PlacementBinding` at the bottom connects this Policy to the `all-managed-clusters` Placement from Step 1; without it, the Policy would exist on the hub but never propagate anywhere.

Check compliance from the hub:

```bash
oc get policy policy-disable-default-catalogs -n acm-policies
```

```
NAME                              REMEDIATION ACTION   COMPLIANCE STATE   AGE
policy-disable-default-catalogs   enforce              Compliant          30s
```

Spot-check one managed cluster directly to confirm the default sources are gone:

```bash
oc get catalogsource -n openshift-marketplace
```

```
No resources found in openshift-marketplace namespace.
```

### Step 3: Distribute Quay Pull Credentials for the Catalog Image

The curated catalog image needs to be reachable from every managed cluster, not just the cluster that built it. Pushing to each cluster's own internal registry works for a single cluster but does not scale: you would be repeating the build-and-push process per cluster forever. A shared registry that every managed cluster can reach is the practical answer for a fleet.

If your organization already has an external image registry reachable from every managed cluster, use that: the tag, push, and pull secret mechanics below work identically regardless of which registry backs them, so skip straight to creating the pull secret once your image is pushed somewhere reachable. If you do not have one yet, quay.io, Red Hat's public hosted Quay service, is a reasonable default since it needs no separate installation, and is what the rest of this step uses. A third option is hosting your own Quay instance rather than depending on an internet-hosted one: the Quay Operator can run a private Quay registry directly on the hub cluster, or on any cluster ACM manages. That is a real deployment of its own and is not covered here, but once running it is used exactly the same way, create a repository, generate credentials, and reference it from the CatalogSource in Step 4.

Create a private repository in Quay (for example `tinyships/curated-operator-catalog`) and push the same image you built in the catalog post to it:

```bash
podman tag curated-operator-catalog:v4.22.10 \
  quay.io/tinyships/curated-operator-catalog:v4.22.10

podman login quay.io

podman push quay.io/tinyships/curated-operator-catalog:v4.22.10
```

Because the repository is private, every managed cluster needs pull credentials. In Quay, open the repository, go to **Robot Accounts**, and create one scoped to **read** access on this repository only; a robot account with pull-only permission on a single repo is a much smaller blast radius than reusing a personal Quay login. From the robot account's **Credentials** tab, download the **Docker Configuration** file; this is a standard `.dockerconfigjson` file.

Create a Secret on the **hub** cluster from that file. This Secret is never committed to git: it stays local to the hub and is referenced by name from the policy, which is the standard way to keep credentials out of GitOps-tracked YAML:

```bash
oc create secret generic quay-robot-creds \
  -n acm-policies \
  --from-file=.dockerconfigjson=<path-to-downloaded-config.json> \
  --type=kubernetes.io/dockerconfigjson
```

Download [3-policy-catalog-pull-secret.yaml](/posts/distributing-custom-catalogs-with-acm/3-policy-catalog-pull-secret.yaml) and apply it:

```bash
oc apply -f 3-policy-catalog-pull-secret.yaml
```

The `object-templates` entry defines a `Secret` named `curated-catalog-pull` in `openshift-marketplace`, of type `kubernetes.io/dockerconfigjson`, the standard Kubernetes type for image registry credentials. Instead of hardcoding the credential value into the YAML, the `.dockerconfigjson` field uses ACM's hub templating syntax: `{{hub fromSecret "acm-policies" "quay-robot-creds" ".dockerconfigjson" hub}}`. This function runs on the hub, reads the named key out of the `quay-robot-creds` Secret you just created, and substitutes the value, already base64-encoded and matching what a Secret's `data` field expects, before the resulting manifest is sent to each managed cluster. The credential itself only ever exists as a Secret object on the hub and inside the Secret this policy creates on each managed cluster; it is never written into a file you would commit to a repository.

Confirm the Secret was created on a managed cluster:

```bash
oc get secret curated-catalog-pull -n openshift-marketplace
```

```
NAME                    TYPE                             DATA   AGE
curated-catalog-pull    kubernetes.io/dockerconfigjson   1      15s
```

### Step 4: Deploy the Custom CatalogSource on Every Managed Cluster

With pull credentials in place, deploy the CatalogSource itself, now pointing at the shared Quay image instead of an internal registry.

Download [4-policy-catalogsource.yaml](/posts/distributing-custom-catalogs-with-acm/4-policy-catalogsource.yaml) and apply it:

```bash
oc apply -f 4-policy-catalogsource.yaml
```

The wrapped `CatalogSource` is nearly identical to the single-cluster version, with two differences. The `image` field now points to `quay.io/tinyships/curated-operator-catalog:v4.22.10`, a reference every managed cluster can resolve, unlike an internal registry service address that only resolves inside the cluster that hosts it. The `secrets` field lists `curated-catalog-pull`, the Secret name from Step 3; this tells OLM's catalog operator which pull secret to use when pulling a private image, the same mechanism a Pod uses `imagePullSecrets` for. Everything else, `sourceType: grpc`, `displayName`, `publisher`, and the `registryPoll.interval: 30m` update check, behaves exactly as it does on a single cluster, just enforced identically on every managed cluster now.

Verify the catalog source pod comes up on a managed cluster:

```bash
oc get pods -n openshift-marketplace -l olm.catalogSource=curated-operators
```

```
NAME                        READY   STATUS    RESTARTS   AGE
curated-operators-xk9j2     1/1     Running   0          25s
```

Confirm the curated operators are discoverable:

```bash
oc get packagemanifest -n openshift-marketplace | wc -l
```

You should see the same thirty-four operators (plus the header line) that appeared on the catalog post's walkthrough, now available on every managed cluster the Placement targets.

### Step 5: Disable the Default Helm Chart Repository Fleet-Wide

The operator catalog is only one of the four content types feeding the Software Catalog page. [Curating the OpenShift Software Catalog](/2026/09/03/curating-the-software-catalog.html) disabled the default `openshift-helm-charts` repository by hand, on one cluster. Wrapping the same resource in a policy means a cluster that gets rebuilt, or a repository someone re-enables while testing a chart, comes back into line automatically instead of drifting silently.

Download [5-policy-disable-helm-chart-repo.yaml](/posts/distributing-custom-catalogs-with-acm/5-policy-disable-helm-chart-repo.yaml) and apply it:

```bash
oc apply -f 5-policy-disable-helm-chart-repo.yaml
```

The `object-templates` entry wraps the exact `HelmChartRepository`/`openshift-helm-charts` object from the software catalog post, `complianceType: musthave`. As with the OperatorHub policy in Step 2, there is no `namespaceSelector` here: `HelmChartRepository` is cluster-scoped, so the object applies once per managed cluster.

Check compliance from the hub:

```bash
oc get policy policy-disable-helm-chart-repo -n acm-policies
```

```
NAME                              REMEDIATION ACTION   COMPLIANCE STATE   AGE
policy-disable-helm-chart-repo   enforce              Compliant          20s
```

Spot-check a managed cluster:

```bash
oc get helmchartrepository openshift-helm-charts -o jsonpath='{.spec.disabled}'
```

```
true
```

### Step 6: Curate Sample Templates Fleet-Wide

Locally, curating a sample Template was a two-part action: add its name to the Samples Operator's skip list, then delete the Template object once yourself, since the skip list only stops the operator from recreating something that is already gone. A policy can make the second part continuous instead of one-time.

Download [6-policy-curate-templates.yaml](/posts/distributing-custom-catalogs-with-acm/6-policy-curate-templates.yaml) and apply it:

```bash
oc apply -f 6-policy-curate-templates.yaml
```

This `ConfigurationPolicy` has two entries in `object-templates`, doing two different jobs. The first, `complianceType: musthave`, targets `config.samples.operator.openshift.io/cluster` and sets only `spec.skippedTemplates: [cakephp-mysql-example]`. Just like the local `oc patch --type merge`, ACM's `musthave` only checks and corrects the fields you actually specify, so it never touches `managementState`, `samplesRegistry`, or `architectures`, values that vary cluster to cluster and that a full-object policy would risk overwriting. The second entry, `complianceType: mustnothave`, targets the `Template` object `cakephp-mysql-example` in the `openshift` namespace directly. This is what turns the one-time manual delete into something ACM enforces continuously: if the Samples Operator, a cluster rebuild, or anyone else ever recreates that Template, ACM deletes it again on the next reconciliation pass without anyone noticing it happened.

Check compliance from the hub:

```bash
oc get policy policy-curate-templates -n acm-policies
```

```
NAME                      REMEDIATION ACTION   COMPLIANCE STATE   AGE
policy-curate-templates   enforce              Compliant          20s
```

Spot-check a managed cluster:

```bash
oc get template cakephp-mysql-example -n openshift
```

```
Error from server (NotFound): templates.template.openshift.io "cakephp-mysql-example" not found
```

### Step 7: Restrict Console Content Types Fleet-Wide

Steps 5 and 6 remove specific items. This step controls an entire content type at once, directly on the Console operator, independent of which Helm repositories or Templates exist on a given cluster, the same defense-in-depth idea covered in the software catalog post's Step 4.

Download [7-policy-restrict-catalog-types.yaml](/posts/distributing-custom-catalogs-with-acm/7-policy-restrict-catalog-types.yaml) and apply it:

```bash
oc apply -f 7-policy-restrict-catalog-types.yaml
```

The `object-templates` entry wraps `consoles.operator.openshift.io/cluster`, setting `spec.customization.developerCatalog.types` to `state: Disabled` with `HelmChart` in the `disabled` list, `complianceType: musthave`. Like the Console operator itself, this is cluster-scoped: no `namespaceSelector` needed.

Check compliance from the hub:

```bash
oc get policy policy-restrict-catalog-types -n acm-policies
```

```
NAME                            REMEDIATION ACTION   COMPLIANCE STATE   AGE
policy-restrict-catalog-types   enforce              Compliant          15s
```

Spot-check a managed cluster:

```bash
oc get consoles.operator.openshift.io cluster \
  -o jsonpath='{.spec.customization.developerCatalog.types}'
```

```
{"disabled":["HelmChart"],"state":"Disabled"}
```

### Step 8: Validate Compliance and Drift Reconciliation

Check the full set of policies from the hub in one view:

```bash
oc get policy -n acm-policies
```

```
NAME                               REMEDIATION ACTION   COMPLIANCE STATE   AGE
policy-disable-default-catalogs   enforce              Compliant          15m
policy-catalog-pull-secret        enforce              Compliant          14m
policy-catalogsource              enforce              Compliant          13m
policy-disable-helm-chart-repo    enforce              Compliant          10m
policy-curate-templates           enforce              Compliant          9m
policy-restrict-catalog-types     enforce              Compliant          8m
```

Every policy showing `Compliant` means every managed cluster the Placement targets has the resources each policy declares. Now prove the reconciliation loop actually works by manually breaking something on a managed cluster:

```bash
oc patch helmchartrepository openshift-helm-charts \
  --type merge \
  --patch '{"spec":{"disabled":false}}'
```

The config-policy-controller add-on watches the exact resources named in its policies, so correction is not a slow periodic sweep: check again a few seconds later and ACM has already put it back:

```bash
oc get helmchartrepository openshift-helm-charts -o jsonpath='{.spec.disabled}'
```

```
true
```

Nobody ran `oc apply` again: the ConfigurationPolicy controller on that managed cluster detected the drift against its declared `musthave` state and corrected it on its own. This is the behavior that makes the catalog configuration durable: a manual mistake, a rebuilt cluster, or a new cluster joining the fleet all converge back to the same declared state without anyone re-running a checklist.

## What You Built

| Policy | Enforces | Scope |
|---|---|---|
| `policy-disable-default-catalogs` | Default OperatorHub sources stay disabled | Every managed cluster |
| `policy-catalog-pull-secret` | Quay pull credentials exist in `openshift-marketplace` | Every managed cluster |
| `policy-catalogsource` | `curated-operators` CatalogSource points at the shared Quay image | Every managed cluster |
| `policy-disable-helm-chart-repo` | Default `openshift-helm-charts` HelmChartRepository stays disabled | Every managed cluster |
| `policy-curate-templates` | `cakephp-mysql-example` stays on the Samples Operator skip list and never exists | Every managed cluster |
| `policy-restrict-catalog-types` | Console Software Catalog hides Helm Charts | Every managed cluster |

Updating the operator catalog itself is unchanged from the catalog post's walkthrough: rebuild and push a new image to the same Quay tag, and the `registryPoll` on every managed cluster's CatalogSource picks it up within thirty minutes, with no policy changes needed. Onboarding a new managed cluster into ACM automatically brings it into scope for every policy bound to `all-managed-clusters`, so it inherits the curated operator catalog and the curated software catalog the moment it is placed.

## References

- [Building a Custom Operator Catalog](/2026/09/03/custom-operator-catalog-rbac.html)
- [Curating the OpenShift Software Catalog](/2026/09/03/curating-the-software-catalog.html)
- [Restricting Operator Installs with RBAC](/2026/09/03/operator-install-rbac.html): not covered by the policies in this post, but the same `ConfigurationPolicy` and `PlacementBinding` pattern applies directly if you want to distribute operator RBAC fleet-wide too
- [Automatic RBAC for New Namespaces with Advanced Cluster Management Policies](/2026/05/17/acm-namespace-rbac-policies.html)
- [ACM Governance and Policy Framework](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html/governance/governance)
- [Quay Documentation: Robot Accounts](https://docs.projectquay.io/use_quay.html#robot-accounts)
