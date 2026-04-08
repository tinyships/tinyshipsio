---
layout: post
title: "Why you should not install Operators in common namespace such as openshift-operators"
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
spec:
  upgradeStrategy: Default
status:
  namespaces:
  - ""
```

The key is `status.namespaces: [""]` — an empty string is the cluster-wide selector. An operator installed into a namespace with this OperatorGroup watches all namespaces. That's appropriate for some operators. The problem isn't the scope; it's putting multiple operators in the same bucket.

When you install an operator from OperatorHub in the web console and select "All Namespaces" as the install mode, the UI silently targets `openshift-operators` as the destination namespace. It doesn't prompt you to consider isolation. This is how operators accumulate there without a deliberate choice.

Check how many subscriptions are already living there:

```bash
oc get subscriptions -n openshift-operators
```

```
NAME                                                                PACKAGE                           SOURCE             CHANNEL
devworkspace-operator-fast-redhat-operators-openshift-marketplace   devworkspace-operator             redhat-operators   fast
loki-operator                                                       loki-operator                     redhat-operators   stable-6.5
openshift-pipelines-operator-rh                                     openshift-pipelines-operator-rh   redhat-operators   latest
web-terminal                                                        web-terminal                      redhat-operators   fast
```

Four operators in the same namespace. You're already in the shared InstallPlan situation.

---

### Step 2: See How Shared InstallPlans Form

This is what the InstallPlans in that namespace actually look like:

```bash
oc get installplan -n openshift-operators -o wide
```

```
NAME            CSV                                       APPROVAL   APPROVED
install-6zbg9   openshift-pipelines-operator-rh.v1.21.1   Manual     true
install-f5jr2   loki-operator.v6.5.0                      Manual     true
install-lszl8   web-terminal.v1.15.0                      Manual     true
```

The `wide` output only shows the first CSV in the plan. To see everything a given InstallPlan will install:

```bash
oc get installplan install-lszl8 -n openshift-operators \
  -o jsonpath='{.spec.clusterServiceVersionNames}'
```

```
["web-terminal.v1.15.0","devworkspace-operator.v0.40.0"]
```

That's the problem, right there. `install-lszl8` looks like a Web Terminal plan, but it includes `devworkspace-operator` too. The DevWorkspace subscription is configured with `Automatic` approval — it's a dependency that OLM pulled in alongside the Web Terminal. But because they share a namespace, OLM bundled both into one InstallPlan. The DevWorkspace approval mode doesn't matter anymore; the whole plan was subject to whatever the most restrictive setting in the namespace required.

If you had been waiting to approve Web Terminal while reviewing what changed, you would have also been holding back DevWorkspace — an operator you may not have realized was even in the plan.

To approve and unblock:

```bash
oc patch installplan install-lszl8 -n openshift-operators \
  --type merge \
  --patch '{"spec":{"approved":true}}'
```

Both operators upgrade simultaneously. There's no mechanism in the current OLM API to split this into separate approvals while they share a namespace.

---

The fix is straightforward: install each operator into its own namespace with its own `OperatorGroup`. InstallPlans are scoped to a namespace, so operators that live in separate namespaces can never be bundled together. The `openshift-operators` namespace still has its uses — quick experiments, evaluating an operator before committing to an install pattern, or running something you genuinely don't care about managing long-term. But for anything you're running in production, or anything you need upgrade control over, give it a dedicated namespace. The marginal cost of a few extra YAML lines per operator is nothing compared to debugging why your carefully set approval gate is silently non-functional.

---

## References

- [Red Hat Solution: InstallPlans referencing more than one operator in openshift-operators namespace](https://access.redhat.com/solutions/6389681)
- [OCP Docs: Operator Lifecycle Manager concepts — OperatorGroup](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/operators/understanding-operators#olm-operatorgroups-concept_olm-understanding-operatorgroups)
- [OCP Docs: Understanding OperatorHub](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/operators/understanding-operators#olm-understanding-operatorhub)
- [How to Find, Install, and Explore an OpenShift Operator from the CLI](/2026/04/06/exploring-openshift-operators.html)
