---
layout: post
title: "Restricting Operator Installs with RBAC"
date: 2026-09-03
---

*Part 2 of 4 in a series on curating and distributing OpenShift catalogs: [Building a Custom Operator Catalog](/2026/09/03/custom-operator-catalog-rbac.html) · **Restricting Operator Installs with RBAC** · [Curating the OpenShift Software Catalog](/2026/09/03/curating-the-software-catalog.html) · [Distributing Custom Operator and Software Catalogs with ACM Policies](/2026/09/03/distributing-custom-catalogs-with-acm.html)*

Anyone with `edit` or `admin` in a namespace that has an OperatorGroup can install anything the cluster's operator catalog offers, whether that catalog is the four default OperatorHub sources or one your organization curated. That is a lot of trust to hand out by accident. This is a quick why and how-to for scoping operator installation down to the namespaces that actually need it, plus a closing look at the one case where a team, not a platform administrator, still needs broad cluster-wide operator access.

## Why This Matters

Every operator installed on a cluster is a controller running with elevated privileges. It registers CRDs into the cluster API, runs reconciliation loops, and often installs webhooks that intercept API requests for its managed resources. Some operators require cluster-admin equivalent permissions to function. None of that is inherently bad, it is what operators are designed to do, but each one adds surface area that needs to be understood, maintained, and secured.

The default OpenShift RBAC model makes all of this available to anyone who can create a Subscription. On a cluster with default RBAC, that includes anyone with `edit` or `admin` in any namespace that has an OperatorGroup. A developer investigating a messaging solution can install AMQ Streams, Strimzi, and three community Kafka operators in the same afternoon, each one registering cluster-scoped CRDs and running controllers. Nobody reviewed whether those operators are compatible with each other, whether they have been tested against the current cluster version, or whether the security team has approved their use.

The fix is namespace-scoped RBAC: give each team a Role that lets them install and manage operators only inside their own namespace, and nothing more. This does not require any new cluster-level RBAC for platform administrators, the default `cluster-admin` role already includes full management of every OLM resource on the cluster, so there is nothing to add there. This works against whatever catalog is already on the cluster, the default Red Hat, Certified, Community, and Marketplace sources, or a curated one.

RBAC alone does not decide what is available, only who can act on it. Whatever operators the catalog exposes are still fair game for anyone granted a Role. If you also want to control which operators show up in the first place, that is a separate, complementary problem covered in [Building a Custom Operator Catalog](/2026/09/03/custom-operator-catalog-rbac.html).

## The Steps

1. Create namespace-scoped RBAC for team-level operator installation
2. Validate the full workflow end-to-end
3. Extend cluster-wide RBAC to a team on a jointly managed cluster

## How To Do It

This walkthrough assumes you have cluster-admin access to an OpenShift cluster with at least one operator catalog available, either the default OperatorHub sources or a curated one. No `opm` or catalog-building tooling is needed here, every resource in this post is a plain RBAC object applied with `oc apply`.

### Step 1: Create Namespace-Scoped RBAC for Team Installation

Not every team needs cluster-wide operator access, and most do not. For teams that should only install operators within their own namespace, create namespace-scoped RBAC. This example sets up a `webapp-team` namespace where the `webapp-team` group can install and manage operators scoped to their namespace only.

Create the team namespace:

```bash
oc create namespace webapp-team
```

Two separate things need to exist in that namespace before the team can install anything: an OperatorGroup, and RBAC that names who is allowed to use it.

An OperatorGroup is not optional scaffolding, it is a hard requirement: OLM refuses to process any Subscription created in a namespace that does not have one. Its `targetNamespaces` field lists exactly which namespaces the operators it covers are allowed to watch and manage. Setting that list to just the team's own namespace is what actually enforces isolation: an operator installed under this OperatorGroup cannot see or modify resources anywhere else on the cluster, regardless of what permissions its own ClusterServiceVersion might otherwise request.

Download [1-team-operatorgroup.yaml](/posts/operator-install-rbac/1-team-operatorgroup.yaml) and apply it:

```bash
oc apply -f 1-team-operatorgroup.yaml
```

With the OperatorGroup in place, OLM will now process Subscriptions in this namespace, but that says nothing about which users are allowed to create one. That is what the Role and RoleBinding are for. The Role `operator-installer` grants the permissions needed to drive the operator installation lifecycle within the namespace: the team can create Subscriptions (which trigger installation) and manage InstallPlans (which control approval) and OperatorGroups (which control scope). They can read ClusterServiceVersions and PackageManifests to check installation status and browse available operators, but cannot modify CSVs directly; OLM manages those. Notably, this Role does not grant access to `catalogsources`, which are cluster-scoped resources in `openshift-marketplace`: the team can use whatever catalog is available but cannot modify or replace it. The RoleBinding is what actually connects a group of users to that Role, in this namespace only; without it, the Role exists but grants nobody anything.

Download [2-team-operator-role.yaml](/posts/operator-install-rbac/2-team-operator-role.yaml) and [3-team-operator-rolebinding.yaml](/posts/operator-install-rbac/3-team-operator-rolebinding.yaml), then apply both:

```bash
oc apply -f 2-team-operator-role.yaml
oc apply -f 3-team-operator-rolebinding.yaml
```

Validate that the webapp team can create subscriptions in their namespace:

```bash
oc auth can-i create subscriptions.operators.coreos.com \
  -n webapp-team \
  --as=placeholder --as-group=webapp-team
```

```
yes
```

Validate that they cannot create subscriptions in other namespaces:

```bash
oc auth can-i create subscriptions.operators.coreos.com \
  -n default \
  --as=placeholder --as-group=webapp-team
```

```
no
```

Validate that they cannot modify the catalog source:

```bash
oc auth can-i delete catalogsources.operators.coreos.com \
  -n openshift-marketplace \
  --as=placeholder --as-group=webapp-team
```

```
no
```

---

### Step 2: Validate the Full Workflow

Test the complete flow: a team member installs an operator in their namespace.

Not every operator supports namespace-scoped installation. Operators like OpenShift Pipelines and GitOps only support `AllNamespaces` install mode and will fail with `OwnNamespace InstallModeType not supported` if installed with a namespace-scoped OperatorGroup. AMQ Streams supports all install modes, making it a good candidate for testing namespace-scoped installation, and it ships in the default `redhat-operators` catalog, so this works whether or not you built a curated catalog.

Download [4-example-subscription.yaml](/posts/operator-install-rbac/4-example-subscription.yaml) and apply it as the webapp team:

```bash
oc apply -f 4-example-subscription.yaml --as=placeholder --as-group=webapp-team
```

The Subscription has two `name` fields that mean different things, plus three others that matter. `metadata.name: webapp-team-amq-streams` is just the Subscription object's own name, arbitrary and chosen by whoever creates it; naming it after the team makes it easy to pick out among every other Subscription on the cluster when you run `oc get subscriptions -A`. `spec.name: amq-streams`, by contrast, is not arbitrary: it must match the package name in the catalog exactly, since this is what tells OLM which package to install. Run `oc get packagemanifest amq-streams -n openshift-marketplace` first if you want to confirm it is available before applying. `channel: stable` picks which update channel to track: a package can ship multiple channels (for example `stable` and `alpha`), and this determines which stream of CSV versions OLM resolves. `source: redhat-operators` and `sourceNamespace: openshift-marketplace` together tell OLM which CatalogSource to pull the operator from; if you followed [Building a Custom Operator Catalog](/2026/09/03/custom-operator-catalog-rbac.html) and want to install from your curated catalog instead, change `source` to `curated-operators`. `installPlanApproval: Manual` means OLM creates the InstallPlan but waits for explicit approval before proceeding, rather than installing immediately. This is the recommended approach for controlled environments: it gives the team a chance to review what will be installed before it happens.

Check that OLM created the InstallPlan:

```bash
oc get installplan -n webapp-team
```

```
NAME            CSV                    APPROVAL   APPROVED
install-8jmb2   amqstreams.v3.2.0-28   Manual     false
```

The team can approve the InstallPlan to proceed with installation:

```bash
INSTALL_PLAN=$(oc get installplan -n webapp-team -o jsonpath='{.items[0].metadata.name}')

oc patch installplan ${INSTALL_PLAN} -n webapp-team \
  --as=placeholder --as-group=webapp-team \
  --type merge \
  --patch '{"spec":{"approved":true}}'
```

Watch the CSV reach `Succeeded`:

```bash
oc get csv -n webapp-team -w
```

```
NAME                   DISPLAY       VERSION    PHASE
amqstreams.v3.2.0-28   AMQ Streams   3.2.0-28   Installing
amqstreams.v3.2.0-28   AMQ Streams   3.2.0-28   Succeeded
```

Confirm that an unprivileged user outside both groups cannot install operators:

```bash
oc auth can-i create subscriptions.operators.coreos.com \
  -n webapp-team \
  --as=placeholder --as-group=random-team
```

```
no
```

RBAC controls who can install operators and where, regardless of which catalog is behind them. Pairing it with a curated catalog closes the other half of the loop: RBAC decides who can act, the catalog decides what they can act on.

---

### Step 3: Extend Cluster-Wide RBAC to a Team on a Jointly Managed Cluster

Namespace scoping covers the common case: several teams sharing one cluster, each fenced into their own namespace. Some clusters do not look like that. A cluster can be dedicated entirely to one application team, who deploy and operate everything on it themselves, with the platform team mostly hands-off day to day. On a cluster like that, the app team plausibly needs to manage operators across the whole cluster, not one namespace, since the whole cluster is theirs to run.

Full `cluster-admin` is the blunt answer to that need, and often the organization's real answer. It is also often more than is actually required, and more than a platform team wants to hand out by default: `cluster-admin` also includes rewriting RBAC itself, deleting arbitrary namespaces, and every other cluster-scoped resource that has nothing to do with operators. The narrower answer is the same `operator-admin` ClusterRole pattern used for platform administrators, bound to the app team's own group instead, with one deliberate gap: this ClusterRole does not include `catalogsources`. The team gets full, cluster-wide control over which operators they subscribe to and how those subscriptions are managed. They do not get to decide which operators exist to choose from in the first place. That is the line: the cluster is theirs to run, the catalog is not.

Download [5-operator-admin-clusterrole.yaml](/posts/operator-install-rbac/5-operator-admin-clusterrole.yaml) and [6-operator-admin-clusterrolebinding.yaml](/posts/operator-install-rbac/6-operator-admin-clusterrolebinding.yaml), then apply both:

```bash
oc apply -f 5-operator-admin-clusterrole.yaml
oc apply -f 6-operator-admin-clusterrolebinding.yaml
```

The ClusterRole `operator-admin` grants full management of four of the five core OLM resources: `subscriptions`, `operatorgroups`, `installplans`, and `clusterserviceversions`. These are the resources involved in the operator installation lifecycle: creating a Subscription triggers OLM to generate an InstallPlan, which when approved installs the CSV. The role also grants read access to `packagemanifests` in the `packages.operators.coreos.com` API group, which is how users browse available operators; PackageManifests are read-only cluster resources generated by OLM from the CatalogSource, so read access here does not conflict with withholding write access to the CatalogSource itself. `catalogsources` is conspicuously absent from the resource list: that omission is the entire point of this Role.

The ClusterRoleBinding binds this role to the `retail-app-admins` group, standing in for whichever group identifies this dedicated cluster's application team. Any user in that group can now manage operators in any namespace on the cluster, but the CatalogSource stays under the platform team's control alone.

Validate that a member of `retail-app-admins` can manage subscriptions cluster-wide:

```bash
oc auth can-i create subscriptions.operators.coreos.com \
  --all-namespaces \
  --as=placeholder --as-group=retail-app-admins
```

```
yes
```

Validate that someone outside the group cannot:

```bash
oc auth can-i create subscriptions.operators.coreos.com \
  -n openshift-operators \
  --as=placeholder --as-group=developers
```

```
no
```

Validate the line in the sand itself: even a member of `retail-app-admins`, with cluster-wide control over subscriptions, cannot touch the catalog source:

```bash
oc auth can-i delete catalogsources.operators.coreos.com \
  -n openshift-marketplace \
  --as=placeholder --as-group=retail-app-admins
```

```
no
```

That last check is the whole design in one command. The app team can install, update, and remove operators anywhere on their cluster without ever filing a ticket with the platform team. What operators are trustworthy enough to be in the catalog at all is a decision the platform team never delegates, on this cluster or any other.

## What You Built

| Layer | What It Controls | How It Works |
|-------|-----------------|--------------|
| `operator-installer` Role | Who can install per-namespace | Members of `webapp-team` group can install operators only in `webapp-team` namespace |
| `operator-admin` ClusterRole (catalog excluded) | Who can install cluster-wide on a jointly managed cluster | Members of `retail-app-admins` group can manage operators in any namespace, but cannot touch CatalogSources |

Adding a new namespace-scoped team is a matter of creating their namespace, OperatorGroup, Role, and RoleBinding, the same four resources from Step 1. Adding a new jointly managed cluster is a matter of binding the same `operator-admin` ClusterRole to that cluster's own team group, per Step 3.

If you also want to control which operators are available in the first place, not just who can install them, see [Building a Custom Operator Catalog](/2026/09/03/custom-operator-catalog-rbac.html).

## References

- [OCP Docs: Understanding RBAC](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/authentication_and_authorization/using-rbac)
- [Why you should not install Operators in common namespace such as openshift-operators](/2026/04/08/openshift-operators-dedicated-namespaces.html)
- [Building a Custom Operator Catalog](/2026/09/03/custom-operator-catalog-rbac.html)
