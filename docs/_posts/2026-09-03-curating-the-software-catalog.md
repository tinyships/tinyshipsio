---
layout: post
title: "Curating the OpenShift Software Catalog"
date: 2026-09-03
---

*Part 3 of 4 in a series on curating and distributing OpenShift catalogs: [Building a Custom Operator Catalog](/2026/09/03/custom-operator-catalog-rbac.html) · [Restricting Operator Installs with RBAC](/2026/09/03/operator-install-rbac.html) · **Curating the OpenShift Software Catalog** · [Distributing Custom Operator and Software Catalogs with ACM Policies](/2026/09/03/distributing-custom-catalogs-with-acm.html)*

Curating the operator catalog closes one door. OpenShift's Software Catalog page also serves Helm Charts, Templates, and Devfiles, and none of those go through OLM at all, so nothing you did to operators touches them. This is a quick why and how-to for finding what else is quietly contributing to that catalog and deciding whether it should be there.

## Why This Matters

The Software Catalog page in the OpenShift console (Developer perspective, or the combined catalog view under a project) is not just an operator browser. It blends four independent content types into one set of tiles: Operators, Helm Charts, Templates, and Devfiles. [Building a Custom Operator Catalog](/2026/09/03/custom-operator-catalog-rbac.html) only deals with the first one. The other three are populated by entirely separate mechanisms, with their own defaults, and most clusters ship all of them wide open without anyone deciding that on purpose.

A fresh OpenShift cluster comes with a single `HelmChartRepository` named `openshift-helm-charts` pointing at `https://charts.openshift.io`, a public community index nobody on your team reviewed. It also ships well over a hundred built-in sample Templates in the `openshift` namespace (things like example CakePHP, Node.js, and Rails application templates), managed by a Samples Operator that actively recreates anything you delete unless you tell it not to. Neither of these went through any approval process. They are just there, the same way the four default operator catalogs were just there before you curated them.

The fix follows the same shape as the operator catalog problem: decide what should be visible, then make the platform enforce it instead of relying on nobody clicking install on the wrong thing. The mechanisms differ by content type, but each one has a real, supported way to say no.

## The Steps

1. Audit what is currently contributing to the Software Catalog
2. Disable or replace the default Helm chart repository
3. Curate the built-in sample Templates
4. Restrict which content types show up at all, cluster-wide

## How To Do It

This walkthrough assumes cluster-admin access to an OpenShift cluster. Nothing here requires `opm`, `podman`, or any tooling beyond `oc`.

### Step 1: Audit What Is Currently Contributing

Before removing anything, see what is actually there. Three independent things feed the catalog, so check all three.

Cluster-scoped Helm chart repositories, available to every project:

```bash
oc get helmchartrepository
```

```
NAME                    AGE
openshift-helm-charts   2d
```

Namespace-scoped Helm chart repositories, which a team can add for their own project without cluster-admin access:

```bash
oc get projecthelmchartrepository -A
```

```
No resources found
```

Built-in sample Templates:

```bash
oc get template -n openshift --no-headers | wc -l
```

```
127
```

On most clusters that first command returns exactly one result, `openshift-helm-charts`, the default community index shipped by the console operator. The second is usually empty until a team adds one of their own. The third is a real number worth pausing on: 127 templates nobody on your team wrote, reviewed, or asked for, all visible to every user with access to the catalog.

---

### Step 2: Disable or Replace the Default Helm Chart Repository

`openshift-helm-charts` is a cluster-scoped custom resource, not something baked into the console image, which means it can be turned off the same way the default operator catalogs were in [Building a Custom Operator Catalog](/2026/09/03/custom-operator-catalog-rbac.html): a `spec.disabled` field.

Download [1-disable-helm-chart-repo.yaml](/posts/curating-the-software-catalog/1-disable-helm-chart-repo.yaml) and apply it:

```bash
oc apply -f 1-disable-helm-chart-repo.yaml
```

The file declares the full existing resource, `name` and `connectionConfig.url` matching what ships by default, with `disabled: true` added. This resource carries the annotation `release.openshift.io/create-only: "true"`, which means the cluster version operator created it once at install time and does not reconcile it afterward; setting `disabled: true` here stays set; nothing will silently flip it back.

Verify it stuck:

```bash
oc get helmchartrepository openshift-helm-charts -o jsonpath='{.spec.disabled}'
```

```
true
```

If a team needs charts from somewhere else, the supported path is a `ProjectHelmChartRepository` scoped to their own namespace rather than re-enabling the cluster-wide one, the same namespace-scoped pattern used for operator RBAC in [Restricting Operator Installs with RBAC](/2026/09/03/operator-install-rbac.html): grant what a specific team needs without reopening it for everyone.

---

### Step 3: Curate the Built-In Sample Templates

Deleting a Template directly does not work by itself. A Samples Operator (`config.samples.operator.openshift.io/cluster`) actively manages the `openshift` namespace and recreates anything it owns that goes missing, unless you tell it to skip that name first.

Check the operator is managing samples:

```bash
oc get config.samples.operator.openshift.io cluster -o jsonpath='{.spec.managementState}'
```

```
Managed
```

Add the templates you want gone to the skip list. This example removes a single sample template; extend the list with as many names as you need:

```bash
oc patch config.samples.operator.openshift.io cluster \
  --type merge \
  --patch '{"spec":{"skippedTemplates":["cakephp-mysql-example"]}}'
```

This is a JSON merge patch on a singleton config resource rather than a downloadable YAML file, on purpose: the `Config` object often already carries other settings (`managementState`, `samplesRegistry`, `architectures`) that vary by cluster, and a merge patch only touches the key you specify, leaving everything else exactly as it was. A full-resource `oc apply` here risks silently wiping fields you did not mean to touch.

Adding a name to `skippedTemplates` only stops the operator from recreating it. You still have to delete the object yourself:

```bash
oc delete template cakephp-mysql-example -n openshift
```

Confirm it does not come back and the count actually dropped:

```bash
oc get template -n openshift --no-headers | wc -l
```

```
126
```

The same `spec.skippedImagestreams` field exists for the ImageStreams the Samples Operator also manages, and `spec.skippedHelmCharts` for a separate set of Helm chart samples it installs directly, independent of the `HelmChartRepository` from Step 2. All three follow the identical pattern: add the name to the skip list, then delete the object once.

---

### Step 4: Restrict Content Types Cluster-Wide

Steps 2 and 3 remove specific items. This step controls entire categories at once, directly on the Console operator, independent of what Helm repositories or Templates exist.

```bash
oc explain console.spec.customization.developerCatalog.types --api-version=operator.openshift.io/v1
```

The field takes a required `state` of either `Enabled` or `Disabled`, plus a matching `enabled` or `disabled` list of catalog type IDs. With `state: Enabled` and a populated `enabled` list, only those types are shown, an allowlist. With `state: Disabled` and a populated `disabled` list, everything shows except those types, a denylist. An empty list under either state shows everything, which is the default on a cluster that has never touched this field.

Hide Helm Charts specifically, cluster-wide, regardless of which repositories exist:

```bash
oc patch consoles.operator.openshift.io cluster \
  --type merge \
  --patch '{"spec":{"customization":{"developerCatalog":{"types":{"state":"Disabled","disabled":["HelmChart"]}}}}}'
```

Verify:

```bash
oc get consoles.operator.openshift.io cluster \
  -o jsonpath='{.spec.customization.developerCatalog.types}'
```

```
{"disabled":["HelmChart"],"state":"Disabled"}
```

`HelmChart` is confirmed directly in the field's own schema documentation as a real type ID. Other types, `Devfile`, `BuilderImage`, `Sample`, and any type a console plugin adds, are not fixed across every cluster and every OpenShift version, so the reliable way to get the exact list for your cluster is the console itself: Administration → Cluster Settings → Configuration → Console → Customization, or by editing the YAML directly in the console, both of which list the live type IDs your specific plugin set has registered.

To undo this and show everything again:

```bash
oc patch consoles.operator.openshift.io cluster \
  --type merge \
  --patch '{"spec":{"customization":{"developerCatalog":{"types":{"state":"Enabled","disabled":null,"enabled":null}}}}}'
```

## What You Built

| Layer | What It Controls | How It Works |
|-------|-------------------|---------------|
| `HelmChartRepository` disabled | Whether the default community chart index is queried | `spec.disabled: true`, stays set because the resource is create-only |
| Samples Operator skip lists | Which built-in Templates, ImageStreams, and Helm chart samples exist | `spec.skippedTemplates` / `skippedImagestreams` / `skippedHelmCharts`, then a one-time manual delete |
| Console `developerCatalog.types` | Which content types are visible at all | Cluster-wide allowlist or denylist, independent of what data sources exist |

None of this touches the operator catalog from [Building a Custom Operator Catalog](/2026/09/03/custom-operator-catalog-rbac.html), they are genuinely independent subsystems, curated the same way for the same reason: decide what should be visible instead of accepting whatever shipped by default.

## References

- [OCP Docs: Working with Helm charts](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/building_applications/working-with-helm-charts)
- [OCP Docs: Configuring the Cluster Samples Operator](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/images/configuring-samples-operator)
- [OCP Docs: Customizing the web console](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/web_console/customizing-web-console)
- [Building a Custom Operator Catalog](/2026/09/03/custom-operator-catalog-rbac.html)
- [Restricting Operator Installs with RBAC](/2026/09/03/operator-install-rbac.html)
