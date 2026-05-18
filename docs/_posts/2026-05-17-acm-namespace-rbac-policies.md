---
layout: post
title: "Automatic RBAC for New Namespaces with Advanced Cluster Management Policies"
date: 2026-05-17
---

Namespaces get created constantly — by teams, by automation, by operators. The RBAC inside those namespaces does not create itself. Someone has to remember to add the right role bindings, and when they do not, you end up with namespaces that the security team cannot see into and the on-call engineer cannot debug. Red Hat Advanced Cluster Management for Kubernetes (ACM) has a policy framework that solves this: you declare what RBAC should exist, which namespaces it applies to, and ACM enforces it continuously across every managed cluster. This is a quick why and how-to for setting up two common patterns — a security baseline that gives a team read-only access to every application namespace, and a targeted policy that grants edit access only to namespaces matching a naming convention.

## Why This Matters

When someone creates a namespace on an OpenShift cluster, the only RBAC that exists in it is whatever the creator already has. There is no inherited policy, no default bindings, no automatic grants. A new namespace is a blank slate.

That is fine as long as only one team needs access. But in practice, at least two groups need visibility into every namespace regardless of who created it: the security team needs read access for compliance and incident response, and the platform team needs it for operational support. Neither group should have to request access per namespace or depend on someone remembering to grant it.

The manual approach — creating RoleBindings after the fact — breaks the moment namespaces are created by automation. Operators create namespaces. CI pipelines create namespaces. Developers create them with a single command and move on. None of those paths include a step for "also create the security team's RoleBinding." The gap between namespace creation and RBAC creation is where access problems live, and it widens every time a new namespace appears without anyone noticing.

ACM's policy framework changes the model. Instead of reacting to namespace creation, you declare the desired state once: "every namespace matching this selector must contain this RoleBinding." The ConfigurationPolicy controller runs on every managed cluster and continuously reconciles against that declaration. When a new namespace appears that matches the selector, the controller creates the resources within seconds. When someone deletes a RoleBinding that the policy says should exist, the controller puts it back. And because ACM tracks compliance centrally, you can see which clusters are in compliance and which are not from a single dashboard on the hub.

---

## The Steps

1. Create a namespace on the hub cluster to hold policy resources and bind it to the managed cluster set
2. Deploy a policy that gives a security team read-only access to all application namespaces automatically
3. Validate the security policy by creating a test namespace and confirming the RoleBinding appears
4. Deploy a second policy that gives a debug team edit access only to namespaces starting with `openshift-debug-`
5. Validate the debug policy with a matching namespace and a non-matching one to confirm the filter works

---

## How To Do It

This walkthrough assumes ACM is installed on your hub cluster and at least one managed cluster is imported. If you have not set that up yet, the [ACM installation documentation](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.12/html/install/installing) covers the operator installation and cluster import process. All commands run against the hub cluster unless noted otherwise.

### Step 1: Create the Policy Namespace and Cluster Binding

ACM policies, Placements, and PlacementBindings are standard Kubernetes resources that live on the hub cluster. Group them in a dedicated namespace to keep them organized and separate from workloads.

Download [1-policy-namespace.yaml](/posts/acm-namespace-rbac-policies/1-policy-namespace.yaml) and apply it:

```bash
oc apply -f 1-policy-namespace.yaml
```

The file contains three resources. The `Namespace` creates `acm-policies` where all policy resources will live. The `ManagedClusterSetBinding` binds the `global` ManagedClusterSet to this namespace — ACM ships with a `global` set that automatically includes every managed cluster, and a Placement can only select clusters from sets that are bound to its namespace. Without this binding, the Placement would match zero clusters and no policy would be distributed. The `Placement` named `all-managed-clusters` selects which managed clusters receive the policies you create. An empty `labelSelector` with no `matchExpressions` matches all clusters in the bound set — which, because you bound the `global` set, means every managed cluster. To target a subset of clusters instead, add label selectors here; for example, `matchLabels: { environment: production }` would limit policy distribution to clusters labeled `environment=production`.

Verify the namespace exists and the Placement resolved your managed clusters:

```bash
oc get namespace acm-policies
```

```
NAME           STATUS   AGE
acm-policies   Active   10s
```

```bash
oc get placement all-managed-clusters -n acm-policies
```

```
NAME                   DECISIONS   REASON                  AGE
all-managed-clusters   1           AllDecisionsScheduled   15s
```

The `DECISIONS` column shows how many clusters the Placement matched. If it shows `0`, check that the ManagedClusterSetBinding was created correctly and that you have at least one managed cluster imported into ACM.

---

### Step 2: Deploy the Security View Policy

This policy creates a RoleBinding in every application namespace on every managed cluster, granting a `security-team` group the built-in `view` ClusterRole. The `view` role provides read-only access to most resources in a namespace — pods, deployments, services, configmaps — without the ability to modify or delete anything.

Download [2-policy-security-view.yaml](/posts/acm-namespace-rbac-policies/2-policy-security-view.yaml) and apply it:

```bash
oc apply -f 2-policy-security-view.yaml
```

The file defines two resources: the Policy and the PlacementBinding that connects it to the Placement you created in Step 1.

The `Policy` resource is the container. `remediationAction: enforce` tells ACM to create missing resources rather than just reporting non-compliance — with `inform` instead, ACM would flag namespaces that lack the RoleBinding but would not create it. `disabled: false` activates the policy immediately.

Inside `policy-templates`, the `ConfigurationPolicy` defines what should exist on each managed cluster. The `namespaceSelector` controls which namespaces the policy applies to. `include: ["*"]` starts by matching every namespace, and `exclude` carves out the system namespaces you do not want to touch: `openshift-*` covers OpenShift's own namespaces, `kube-*` covers Kubernetes system namespaces, and `default` is excluded because it is typically unused but carries special semantics. Adjust these exclusions to match your environment — if your organization uses additional namespace prefixes for infrastructure, add them to the exclude list.

The `object-templates` section defines the resource the policy creates in each matched namespace. `complianceType: musthave` means the resource must exist with at least the fields specified — ACM creates it if missing and updates it if the key fields drift, but does not remove extra fields that someone adds manually. The `RoleBinding` binds the `security-team` Group to the `view` ClusterRole. Any user whose OpenShift identity includes membership in a group named `security-team` — whether that group comes from an OIDC provider, LDAP sync, or manual creation — receives read-only access to every matched namespace automatically.

The `PlacementBinding` connects the Policy to the Placement. Without it, the Policy exists on the hub but is never distributed to any managed cluster.

Check that the policy is compliant:

```bash
oc get policy policy-security-view -n acm-policies
```

```
NAME                   REMEDIATION ACTION   COMPLIANCE STATE   AGE
policy-security-view   enforce              Compliant          30s
```

`Compliant` means ACM has verified that every matched namespace on every managed cluster contains the required RoleBinding. If you see `NonCompliant` with `enforce` mode, ACM is actively creating the missing bindings — check again after a few seconds.

---

### Step 3: Validate the Security View Policy

Create a test namespace on a managed cluster to confirm the RoleBinding appears automatically.

```bash
oc create namespace rbac-test
```

The ConfigurationPolicy controller runs a reconciliation loop on the managed cluster. Within a few seconds of the namespace being created, ACM detects it, matches it against the `namespaceSelector`, and creates the RoleBinding:

```bash
oc get rolebinding security-team-view -n rbac-test
```

```
NAME                 ROLE               AGE
security-team-view   ClusterRole/view   5s
```

The RoleBinding exists without anyone creating it manually. Verify the permissions it grants:

```bash
oc auth can-i get pods -n rbac-test --as=placeholder --as-group=security-team
```

```
yes
```

```bash
oc auth can-i delete pods -n rbac-test --as=placeholder --as-group=security-team
```

```
no
```

The `security-team` group can read resources in the namespace but cannot modify them — exactly what a view role provides. The `--as=placeholder` value is required because OpenShift needs both `--as` and `--as-group` together for group impersonation; the username is arbitrary since the authorization is evaluated against the group binding.

Confirm the policy does not apply to system namespaces by checking one of the excluded patterns:

```bash
oc get rolebinding security-team-view -n openshift-monitoring 2>&1
```

```
Error from server (NotFound): rolebindings.rbac.authorization.k8s.io "security-team-view" not found
```

The security view binding was not created in `openshift-monitoring` because it matches the `openshift-*` exclusion. Clean up the test namespace:

```bash
oc delete namespace rbac-test
```

---

### Step 4: Deploy the Debug Namespace Policy

This second policy targets a narrower set of namespaces. Instead of matching everything, it only applies to namespaces whose names start with `openshift-debug-`. This pattern is useful when teams use naming conventions to signal intent — debug namespaces created during incident response, sandbox environments, or namespaces tied to a specific workflow where a known group needs immediate access.

Download [3-policy-debug-rbac.yaml](/posts/acm-namespace-rbac-policies/3-policy-debug-rbac.yaml) and apply it:

```bash
oc apply -f 3-policy-debug-rbac.yaml
```

The structure is identical to the security view policy with two key differences. The `namespaceSelector` uses `include: ["openshift-debug-*"]` with no `exclude` list. Only namespaces whose names begin with `openshift-debug-` are matched — every other namespace is ignored entirely. This means you do not need to worry about this policy creating bindings in application namespaces or other `openshift-` system namespaces that do not match the prefix.

The `RoleBinding` in the `object-templates` grants the `debug-team` group the built-in `edit` ClusterRole instead of `view`. The `edit` role allows creating and managing workloads — pods, deployments, services, configmaps, secrets — which is what someone debugging a live issue actually needs. It does not grant RBAC modification or access to cluster-scoped resources, so the debug team cannot escalate their own permissions.

The `severity` is set to `medium` rather than `low`. Severity does not change enforcement behavior — ACM enforces regardless — but it surfaces in the compliance dashboard and any integration you have with alerting or ticketing. A missing debug binding is more operationally urgent than a missing view binding, and the severity label communicates that.

Check policy compliance:

```bash
oc get policy policy-debug-namespace-rbac -n acm-policies
```

```
NAME                          REMEDIATION ACTION   COMPLIANCE STATE   AGE
policy-debug-namespace-rbac   enforce              NonCompliant       20s
```

**NOTE:** If no `openshift-debug-*` namespaces exist yet, ACM reports `NonCompliant` with a message like `namespaced object debug-team-edit of kind RoleBinding has no namespace specified from the policy namespaceSelector nor the object metadata`. This is expected — the `namespaceSelector` resolved to zero namespaces, so the controller has no target namespace for the RoleBinding and cannot verify compliance. The policy becomes `Compliant` as soon as you create a namespace that matches the prefix, which is what you will do in the next step.

---

### Step 5: Validate the Debug Namespace Policy

From the managed cluster create a namespace that matches the prefix:

```bash
oc create namespace openshift-debug-incident-42
```

Check for the RoleBinding:

```bash
oc get rolebinding debug-team-edit -n openshift-debug-incident-42
```

```
NAME              ROLE               AGE
debug-team-edit   ClusterRole/edit   5s
```

Verify the permissions:

```bash
oc auth can-i create deployments -n openshift-debug-incident-42 \
  --as=placeholder --as-group=debug-team
```

```
yes
```

```bash
oc auth can-i create clusterrolebindings \
  --as=placeholder --as-group=debug-team
```

```
no
```

The debug team can create and manage workloads in the debug namespace but cannot modify RBAC or cluster-level resources.

Notice that the security view policy from Step 2 does not apply here — `openshift-debug-incident-42` starts with `openshift-`, which is in the security policy's exclude list:

```bash
oc get rolebinding security-team-view -n openshift-debug-incident-42 2>&1
```

```
Error from server (NotFound): rolebindings.rbac.authorization.k8s.io "security-team-view" not found
```

This is the expected behavior. The two policies operate independently with their own namespace selectors. If you want the security team to also have visibility into debug namespaces, add a second entry to the security policy's `include` list — `"openshift-debug-*"` — or create a separate policy targeting that prefix with the `view` role.

Clean up the test namespaces:

```bash
oc delete namespace openshift-debug-incident-42 test-no-debug
```

---

## What You Built

By the end of this walkthrough you have two ACM policies running across every managed cluster:

| Policy | Scope | Group | Role | Effect |
|---|---|---|---|---|
| `policy-security-view` | All non-system namespaces | `security-team` | `view` | Read-only access everywhere |
| `policy-debug-namespace-rbac` | `openshift-debug-*` namespaces only | `debug-team` | `edit` | Full workload management in debug namespaces |

Both policies enforce continuously. When a new namespace is created on any managed cluster, ACM evaluates it against every active policy's `namespaceSelector` within seconds. If it matches, the defined RoleBindings are created automatically. If someone deletes a RoleBinding that a policy says should exist, ACM recreates it. There is no cron job, no webhook, no external controller — ACM's ConfigurationPolicy controller handles it as part of its normal reconciliation loop.

The pattern extends naturally. A third policy could grant an `oncall` group `admin` access to namespaces labeled `tier: critical`. A fourth could create NetworkPolicies or LimitRanges in every new namespace using the same mechanism. Declare the desired state in a ConfigurationPolicy, define the `namespaceSelector`, set `remediationAction: enforce`, and ACM handles the rest.

---

## References

- [ACM Governance and Policy Framework](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html/governance/governance)
- [OCP Docs: Understanding RBAC](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/authentication_and_authorization/using-rbac)
