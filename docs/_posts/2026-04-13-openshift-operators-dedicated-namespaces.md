---
layout: post
title: "Why you should not install Operators in openshift-operators"
date: 2026-04-13
---

> **Work in Progress** — This post is still being written and may be incomplete.

OpenShift ships with an `openshift-operators` namespace that looks like the obvious place to put operators. The OperatorHub UI defaults to it for any operator with "All Namespaces" scope. And when you're installing something quickly, it's the path of least resistance. This is a quick why and how-to for understanding what actually happens inside that namespace — how OLM's dependency resolution works, why shared namespaces silently undermine upgrade control, and what the alternative looks like.

## Why This Matters

When you install an operator through OLM, it creates an `InstallPlan` in the same namespace as the `Subscription`. An `InstallPlan` is OLM's resolved answer to "what exactly needs to be installed to satisfy this subscription" — it lists the CSVs, their dependencies, and the order they go in. The `approved` field on that InstallPlan is the gate: if approval is `Automatic`, OLM approves it and proceeds immediately. If it's `Manual`, nothing moves until a human sets `approved: true`.

Here's where `openshift-operators` becomes a trap. OLM's current namespaced API design treats all operators in a namespace as one big set for dependency resolution — whether they're related or not. Updating any one operator in `openshift-operators` triggers an update of *all* operators in that namespace. An InstallPlan in that namespace can — and routinely does — reference every operator that has an available upgrade.

What that produces in practice: if you've set `Manual` approval on any one operator so your team can review changes before applying them, every other operator in the namespace stops auto-updating too, even if their Subscriptions say `Automatic`. Red Hat's own support documentation states this directly: *"When an operator is configured with an automatic approvalMode, the OpenShift GUI displays the Update approval status as Automatic Functioning as manual."* The UI shows Automatic; the behavior is Manual. That's a hard mismatch to debug if you didn't know to look for it.

The reverse is also a problem. If you want to upgrade a single operator on a controlled schedule, OLM creates an InstallPlan for *all possible operators that can be upgraded* in the namespace and asks you to approve all of them together. You have no mechanism to approve upgrades for one operator while holding others.

This is not a bug — it is the documented, expected behavior of the current OLM API design. The root cause is that dependency resolution operates at the namespace level, not the subscription level. And because the OperatorHub UI defaults global operators into `openshift-operators`, the side effect accumulates silently.

It's worth slowing down on this. Upgrade control is one of the most operationally important levers you have. If your upgrade approval is silently non-functional in either direction, you've lost the ability to manage operator changes on your own terms.

---

## The Steps

1. Understand what `openshift-operators` is and why it's the default
2. See how shared InstallPlans form when multiple Subscriptions land in the same namespace
3. Create a dedicated namespace and OperatorGroup for each operator instead
4. Verify that InstallPlans are now isolated and upgrade behavior is independent

---

## How To Do It

### Step 1: What openshift-operators Actually Is

Every OpenShift cluster ships with an `openshift-operators` namespace containing a pre-created `OperatorGroup` called `global-operators`. You can inspect it:

```bash
oc get operatorgroup global-operators -n openshift-operators -o yaml
```

```yaml
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: global-operators
  namespace: openshift-operators
spec: {}
```

The empty `spec` — specifically, no `targetNamespaces` field — is the cluster-wide selector. An operator installed into a namespace with this OperatorGroup watches all namespaces. That's appropriate for some operators. The problem isn't the scope; it's putting multiple operators in the same bucket.

When you install an operator from OperatorHub in the web console and select "All Namespaces" as the install mode, the UI silently targets `openshift-operators` as the destination namespace. It doesn't prompt you to consider isolation. The Web Terminal Operator is a good example — it's a Red Hat operator that provides an in-browser terminal in the OpenShift console, and installing it through the UI drops it straight into `openshift-operators` by default. This is how operators accumulate there without a deliberate choice.

Check how many subscriptions are already living there:

```bash
oc get subscriptions -n openshift-operators
```

If you see more than one, you're already in the shared InstallPlan situation.

---

### Step 2: See How Shared InstallPlans Form

Say you've installed the Web Terminal Operator and the Kiali Operator both into `openshift-operators` — the Web Terminal with `Automatic` approval and Kiali with `Manual` so your team can review service mesh changes before they go in. When updates become available for both, check what OLM generates:

```bash
oc get installplan -n openshift-operators -o wide
```

```
NAME            CSV                                                      APPROVAL    APPROVED
install-xk2pj   web-terminal.v1.9.0                                      Automatic   true
install-m8qzr   web-terminal.v1.10.0,kiali-operator.v1.73.0              Manual      false
```

That second line is the problem. The Web Terminal's Subscription says `Automatic`, but its upgrade to `v1.10.0` got bundled into the same InstallPlan as Kiali, which has `Manual` approval. The whole plan is blocked. The Web Terminal won't update until someone manually approves the plan — and when they do, Kiali upgrades at the same time.

To see exactly what a pending InstallPlan will install before approving:

```bash
oc get installplan install-m8qzr -n openshift-operators \
  -o jsonpath='{.spec.clusterServiceVersionNames}'
```

```
["web-terminal.v1.10.0","kiali-operator.v1.73.0"]
```

If there's only one item in that list, you're safe. If there are multiple, you're approving all of them together regardless of what each individual Subscription says.

To approve and unblock:

```bash
oc patch installplan install-m8qzr -n openshift-operators \
  --type merge \
  --patch '{"spec":{"approved":true}}'
```

Both operators upgrade simultaneously. There's no mechanism in the current OLM API to split this into separate approvals while they share a namespace.

---

### Step 3: What Installing in a Dedicated Namespace Looks Like

Installing each operator into its own namespace with its own `OperatorGroup` is the way to guarantee OLM creates isolated InstallPlans — they can never be bundled because they live in separate namespaces.

The Web Terminal Operator needs cluster-wide access to inject a terminal into the console regardless of which namespace a user is working in, so the OperatorGroup uses an empty `spec` — the same cluster-wide scope as `global-operators`, just in a namespace of its own:

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-web-terminal
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: web-terminal-operators
  namespace: openshift-web-terminal
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: web-terminal
  namespace: openshift-web-terminal
spec:
  channel: fast
  installPlanApproval: Automatic
  name: web-terminal
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

For operators that only need to watch a specific namespace, scope the `OperatorGroup` with `targetNamespaces` instead of an empty `spec`. But for anything that genuinely needs cluster-wide access, the empty `spec` is correct — the isolation comes from the namespace boundary, not from restricting the scope.

The naming pattern here follows what Red Hat does with their own operators: `openshift-logging`, `openshift-storage`, `openshift-acm`. The namespace name describes the workload, not "operators" generically. One namespace, one operator, one OperatorGroup.

---

### Step 4: Verify InstallPlan Isolation

After applying the YAML, check that the Web Terminal gets its own independent InstallPlan:

```bash
oc get installplan -n openshift-web-terminal
```

```
NAME            CSV                      APPROVAL    APPROVED
install-ab3c1   web-terminal.v1.9.0      Automatic   true
```

Only one CSV. No other operators in the plan. Confirm the subscription resolved:

```bash
oc get subscription web-terminal -n openshift-web-terminal \
  -o jsonpath='{.status.installedCSV}{"\n"}'
```

```
web-terminal.v1.9.0
```

And verify the CSV reached `Succeeded`:

```bash
oc get csv -n openshift-web-terminal
```

```
NAME                    DISPLAY                VERSION   PHASE
web-terminal.v1.9.0     Web Terminal           1.9.0     Succeeded
```

From here, when `v1.10.0` becomes available, OLM creates a new InstallPlan in `openshift-web-terminal` only. Kiali — now in its own namespace — generates its own separate InstallPlan on its own schedule. Approving one has no effect on the other.

If you switch the Web Terminal to `Manual` approval to review a specific upgrade, check what the pending plan contains before approving:

```bash
oc get installplan -n openshift-web-terminal -o yaml | grep -A5 "clusterServiceVersionNames"
```

```yaml
spec:
  clusterServiceVersionNames:
  - web-terminal.v1.10.0
  approval: Manual
  approved: false
```

One name in that list. Approve it and you know exactly what changes.

---

The `openshift-operators` namespace still has its uses — quick experiments, evaluating an operator before committing to an install pattern, or running something you genuinely don't care about managing long-term. But for anything you're running in production, or anything you need upgrade control over, give it a dedicated namespace. The marginal cost of three extra YAML lines per operator is nothing compared to debugging why your carefully set manual approval gate silently stopped working.

---

## References

- [Red Hat Solution: InstallPlans referencing more than one operator in openshift-operators namespace](https://access.redhat.com/solutions/6389681)
- [OCP Docs: Operator Lifecycle Manager concepts — OperatorGroup](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/operators/understanding-operators#olm-operatorgroups-concept_olm-understanding-operatorgroups)
- [OCP Docs: Understanding OperatorHub](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/operators/understanding-operators#olm-understanding-operatorhub)
- [How to Find, Install, and Explore an OpenShift Operator from the CLI](/2026/04/06/exploring-openshift-operators.html)
