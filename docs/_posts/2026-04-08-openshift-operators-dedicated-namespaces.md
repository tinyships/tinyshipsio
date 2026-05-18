---
layout: post
title: "Why you should not install Operators in common namespace such as openshift-operators"
date: 2026-04-08
---

OpenShift ships with an `openshift-operators` namespace that looks like the obvious place to put operators. The OperatorHub UI defaults to it for any operator with "All Namespaces" scope. This is a quick why and how-to for understanding what actually happens inside that namespace — and why it quietly removes your ability to upgrade operators on your own terms.

## Why This Matters

When OLM installs an operator, it creates an `InstallPlan` in the same namespace as the `Subscription`. That InstallPlan is OLM's resolved list of everything that needs to be installed — the CSVs, their dependencies, and the order they go in. The `approved` field is the gate: `Automatic` means OLM proceeds immediately, `Manual` means nothing moves until a human approves it.

The catch is that OLM resolves dependencies at the namespace level, not the subscription level. Every operator in a namespace gets pulled into the same InstallPlan. So when any operator has an available upgrade, OLM creates a single plan covering all operators in that namespace that can be upgraded — not just the one you care about.

That has two consequences worth sitting with. First, if you want to upgrade one operator, you are also upgrading every other operator in that namespace that has an available update. There is no mechanism to split them. Second, if any one subscription in the namespace is set to `Manual` approval, the entire plan waits for human sign-off — including operators whose subscriptions say `Automatic`. The UI will show those as Automatic. The behavior is Manual. Red Hat's own support documentation calls this out directly.

This is not a bug. It is the documented behavior of the current OLM API. The problem is that it accumulates silently because the OperatorHub UI never tells you it is happening.

---

## The Steps

1. Inspect the `openshift-operators` namespace to see how many subscriptions are sharing it
2. Examine an InstallPlan to confirm that a single plan spans multiple operators

---

## How To Do It

### Step 1: See what is sharing the namespace

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

Four operators in the same namespace. Each one is now part of the same dependency resolution pool.

---

### Step 2: Inspect an InstallPlan to see the bundling

```bash
oc get installplan -n openshift-operators -o wide
```

```
NAME            CSV                                       APPROVAL   APPROVED
install-6zbg9   openshift-pipelines-operator-rh.v1.21.1   Manual     true
install-f5jr2   loki-operator.v6.5.0                      Manual     true
install-lszl8   web-terminal.v1.15.0                      Manual     true
```

The `wide` output only shows the first CSV in each plan. Pull the full list for one:

```bash
oc get installplan install-lszl8 -n openshift-operators \
  -o jsonpath='{.spec.clusterServiceVersionNames}'
```

```
["web-terminal.v1.15.0","devworkspace-operator.v0.40.0"]
```

That is the problem. `install-lszl8` looks like a Web Terminal plan, but it includes `devworkspace-operator` too. Approving it upgrades both. There is no way to approve one without the other while they share a namespace.

To approve:

```bash
oc patch installplan install-lszl8 -n openshift-operators \
  --type merge \
  --patch '{"spec":{"approved":true}}'
```

Both operators upgrade simultaneously.

---

The fix is to give each operator its own namespace and its own `OperatorGroup`. InstallPlans are scoped to a namespace, so operators in separate namespaces can never be bundled together. The `openshift-operators` namespace is still useful for quick experiments or operators you do not need to manage long-term. But for anything in production, or anything you need upgrade control over, a dedicated namespace is the right call.

---

## References

- [Red Hat Solution: InstallPlans referencing more than one operator in openshift-operators namespace](https://access.redhat.com/solutions/6389681)
- [OCP Docs: Operator Lifecycle Manager concepts — OperatorGroup](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/operators/understanding-operators#olm-operatorgroups-concept_olm-understanding-operatorgroups)
- [OCP Docs: Understanding OperatorHub](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/operators/understanding-operators#olm-understanding-operatorhub)
- [How to Find, Install, and Explore an OpenShift Operator from the CLI](/2026/04/06/exploring-openshift-operators.html)
