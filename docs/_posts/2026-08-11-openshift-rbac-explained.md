---
layout: post
title: "OpenShift RBAC Explained: From Default Roles to Custom Permissions"
date: 2026-08-11
---

Three teams share one OpenShift cluster. A developer on Team A accidentally deletes a deployment owned by Team B. A CI pipeline running under a service account with cluster-admin gets its token leaked, and an attacker has unrestricted access to every namespace. A new engineer creates a project, deploys a workload with no resource limits, and starves the monitoring stack of CPU. These are not hypothetical scenarios — they are what happens when RBAC is left at its defaults. This is a quick why and how-to for understanding how OpenShift RBAC works and setting up users with different permission levels so you can see the access model in action.

## Why This Matters

OpenShift ships with an access control system that most administrators interact with indirectly — someone runs `oc adm policy add-cluster-role-to-user cluster-admin` during initial setup, the console works, and the topic gets shelved until something breaks. The problem is that "something breaks" in RBAC usually means unauthorized access, accidental deletion, or a compliance finding — all of which are expensive to fix after the fact.

The access model in OpenShift is deny-by-default. If a user does not have an explicit grant for an action, the API server returns 403 Forbidden. There is no inheritance between namespaces. A RoleBinding in `namespace-a` has zero effect in `namespace-b`. This is fundamentally different from systems like VMware vCenter, where permissions can propagate from a parent folder to every child object underneath it. In OpenShift, silence is always denial.

That design is powerful, but it means you need to be deliberate about what you grant. The built-in roles — `view`, `edit`, `admin`, `cluster-admin`, `cluster-reader` — cover most common patterns. Understanding what each one actually permits, where those permissions apply, and how they compose is the difference between a cluster that enforces least privilege and one that has cluster-admin tokens scattered across CI pipelines.

Taking the time to set up a few demo users with different permission levels is the fastest way to make RBAC concrete. You log in as each user, try things, get denied, and build an intuitive understanding of how the boundaries work. That understanding pays for itself the first time you need to grant a contractor temporary access or scope a service account for a deployment pipeline.

---

## The Steps

1. Understand the three building blocks of RBAC: Rules, Roles, and RoleBindings
2. Review the default ClusterRoles that ship with every OpenShift cluster
3. Add an HTPasswd identity provider with five demo users at different permission levels
4. Create ClusterRoleBindings for cluster-wide access and RoleBindings for namespace-scoped access
5. Test each user to verify the permission boundaries hold
6. Build a custom Role for fine-grained access control
7. Use `oc auth can-i` and `oc adm policy who-can` to audit permissions

---

## How To Do It

### Step 1: Understand Rules, Roles, and RoleBindings

RBAC in OpenShift is built from three components. Every permission grant in the cluster traces back to these three pieces.

A **Rule** is a single permission statement. It specifies a verb (the action), a resource (the object), and an API group (which API the resource belongs to). For example: verb `get`, resource `pods`, apiGroup `""` (the core API group). That single rule says "read pods." Rules are additive — you can only allow actions, never deny them. If a rule is not present, the action is denied.

A **Role** is a named collection of rules, scoped to a single namespace. A **ClusterRole** is the same thing but applies cluster-wide, and can also grant access to cluster-scoped resources like nodes and persistent volumes that do not live in any namespace.

A **RoleBinding** connects a Role to a subject — a User, Group, or ServiceAccount — in a specific namespace. A **ClusterRoleBinding** does the same thing but grants the permissions across the entire cluster.

Here is a Role that allows reading pods and updating deployments in one namespace:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-operator
  namespace: rbac-demo
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch", "update", "patch"]
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list", "watch"]
```

Each rule has three fields. `apiGroups` is which API the resource belongs to — `""` is the core API (pods, services, secrets), `apps` covers deployments, statefulsets, and daemonsets. `resources` is the object type, always the lowercase plural form of the Kind. `verbs` is the list of allowed actions: `get`, `list`, `watch`, `create`, `update`, `patch`, `delete`.

There is an important subtlety with ClusterRoles: a ClusterRole bound via a **RoleBinding** (not a ClusterRoleBinding) grants those permissions only in the namespace where the RoleBinding lives. This is how the built-in `edit` role works — it is a ClusterRole, but developers get it through a RoleBinding scoped to their namespace. The ClusterRole definition is reusable; the binding controls where it applies.

Verify you understand the concept by reading through the built-in `edit` ClusterRole:

```bash
oc describe clusterrole edit
```

You will see every verb and resource combination that `edit` permits. No ambiguity, no hidden grants — the permission matrix is explicit.

---

### Step 2: Review the Default ClusterRoles

Every OpenShift cluster ships with a set of default ClusterRoles. Before writing custom roles, know what is already available:

| ClusterRole | Scope | What It Permits |
|---|---|---|
| `cluster-admin` | Cluster-wide | Every action on every resource. Full control over quota, RBAC, and all namespaces. |
| `cluster-reader` | Cluster-wide | Read-only access to most resources across all namespaces. Cannot modify anything. |
| `admin` | Namespace (via RoleBinding) | Full control within a namespace — manage resources, create RoleBindings, manage quotas. Cannot modify the namespace itself or cluster-level resources. |
| `edit` | Namespace (via RoleBinding) | Create and modify most resources in a namespace (pods, deployments, services, secrets, configmaps). Cannot manage RBAC or project settings. |
| `view` | Namespace (via RoleBinding) | Read-only access within a namespace. Can see pods, deployments, services, and configmaps but cannot view secrets or modify anything. |
| `self-provisioner` | Cluster-wide (default) | Allows authenticated users to create new projects. Often removed in production multi-tenant clusters. |
| `basic-user` | Cluster-wide (default) | Allows authenticated users to list projects and get their own user info. |

List the non-system ClusterRoles on your cluster to see what is available:

```bash
oc get clusterroles | grep -v "^system:" | grep -v "^openshift:"
```

Two default grants are worth understanding early. Run:

```bash
oc describe clusterrolebinding self-provisioners
```

Every user who authenticates via OAuth is bound to `self-provisioner` by default. That means any authenticated user can create a new project and become its admin — useful for developer sandboxes, inappropriate for production multi-tenant clusters. Removing this is one of the first hardening steps after installation.

---

### Step 3: Add an HTPasswd Identity Provider

HTPasswd is the simplest identity provider for testing. It stores usernames and bcrypt-hashed passwords in a flat file, backed by a Secret in the `openshift-config` namespace. There is no external service to manage.

Create the password file with five demo users. Each user will get a different level of access:

```bash
htpasswd -cbB /tmp/demo-users.htpasswd demo-clusteradmin 'demo1234'
htpasswd -bB /tmp/demo-users.htpasswd demo-clusterreader 'demo1234'
htpasswd -bB /tmp/demo-users.htpasswd demo-admin 'demo1234'
htpasswd -bB /tmp/demo-users.htpasswd demo-editor 'demo1234'
htpasswd -bB /tmp/demo-users.htpasswd demo-viewer 'demo1234'
```

The `-c` flag creates the file (only used for the first entry). The `-B` flag specifies bcrypt hashing. Verify the file looks correct:

```bash
cat /tmp/demo-users.htpasswd
```

```
demo-clusteradmin:$2y$05$wDqv...
demo-clusterreader:$2y$05$Nygz...
demo-admin:$2y$05$AmIz...
demo-editor:$2y$05$BMn1...
demo-viewer:$2y$05$M0Kq...
```

Create the Secret in the `openshift-config` namespace. Download [1-htpasswd-secret.yaml](../posts/openshift-rbac-explained/1-htpasswd-secret.yaml) for reference, but the CLI approach is more practical since it handles the hashing for you:

```bash
oc create secret generic demo-htpasswd-secret \
  --from-file=htpasswd=/tmp/demo-users.htpasswd \
  -n openshift-config
```

This creates a Secret named `demo-htpasswd-secret` containing the HTPasswd file. The key inside the Secret must be named `htpasswd` — that is what the OAuth server looks for.

Verify the Secret was created:

```bash
oc get secret demo-htpasswd-secret -n openshift-config
```

```
NAME                     TYPE     DATA   AGE
demo-htpasswd-secret     Opaque   1      5s
```

Now patch the cluster OAuth configuration to add HTPasswd as an identity provider. If you already have an existing provider (like Keycloak or LDAP), this adds HTPasswd alongside it — it does not replace anything. Download [2-oauth-htpasswd-patch.yaml](../posts/openshift-rbac-explained/2-oauth-htpasswd-patch.yaml) for the full resource reference.

```bash
oc patch oauth cluster --type=json \
  -p '[{
    "op": "add",
    "path": "/spec/identityProviders/-",
    "value": {
      "name": "demo-htpasswd",
      "mappingMethod": "claim",
      "type": "HTPasswd",
      "htpasswd": {
        "fileData": {
          "name": "demo-htpasswd-secret"
        }
      }
    }
  }]'
```

This JSON patch appends (`/-` means append to array) a new identity provider entry. The `mappingMethod: claim` means each identity from this provider claims a unique user — if no existing user matches, a new one is created on first login. The `fileData.name` points to the Secret you just created.

The OAuth operator detects the configuration change and rolls the `oauth-openshift` pods in the `openshift-authentication` namespace. Wait for the rollout to complete:

```bash
oc get pods -n openshift-authentication -w
```

When you see the new pod reach `1/1 Running`, press Ctrl+C. Verify the identity provider appears in the OAuth configuration:

```bash
oc get oauth cluster -o jsonpath='{range .spec.identityProviders[*]}{.name}{" ("}{.type}{")\n"}{end}'
```

```
demo-htpasswd (HTPasswd)
```

If you have an existing provider, you will see it listed as well. Both providers are active simultaneously — users authenticate against whichever provider recognizes their credentials.

---

### Step 4: Create the RBAC Bindings

The users exist in the identity provider, but they have no permissions on the cluster yet. OpenShift creates the User object on first login — the "User not found" warnings you will see when creating bindings before that first login are expected and harmless.

First, create a namespace for the namespace-scoped demo users. Download [3-demo-namespace.yaml](../posts/openshift-rbac-explained/3-demo-namespace.yaml) for the manifest.

```bash
oc apply -f 3-demo-namespace.yaml
```

Verify the namespace exists:

```bash
oc get namespace rbac-demo
```

```
NAME        STATUS   AGE
rbac-demo   Active   5s
```

Now create the cluster-wide bindings. Download [4-cluster-rolebindings.yaml](../posts/openshift-rbac-explained/4-cluster-rolebindings.yaml) and apply it:

```bash
oc apply -f 4-cluster-rolebindings.yaml
```

This file contains two ClusterRoleBindings:

- `demo-clusteradmin-binding` — binds the `cluster-admin` ClusterRole to user `demo-clusteradmin`. This user will have unrestricted access to every resource on the cluster.
- `demo-clusterreader-binding` — binds the `cluster-reader` ClusterRole to user `demo-clusterreader`. This user can read most resources across all namespaces but cannot modify anything.

Verify the cluster-scoped bindings:

```bash
oc get clusterrolebindings | grep demo
```

```
demo-clusteradmin-binding    ClusterRole/cluster-admin    ...
demo-clusterreader-binding   ClusterRole/cluster-reader   ...
```

Next, create the namespace-scoped bindings. Download [5-namespace-rolebindings.yaml](../posts/openshift-rbac-explained/5-namespace-rolebindings.yaml) and apply it:

```bash
oc apply -f 5-namespace-rolebindings.yaml
```

This file contains three RoleBindings, all scoped to the `rbac-demo` namespace:

- `demo-admin-binding` — binds the `admin` ClusterRole to user `demo-admin` in `rbac-demo`. This user can manage resources, create additional RoleBindings, and administer everything within this namespace — but has zero access anywhere else.
- `demo-editor-binding` — binds the `edit` ClusterRole to user `demo-editor` in `rbac-demo`. This user can create and modify workloads (pods, deployments, services, configmaps, secrets) but cannot manage RBAC or project settings.
- `demo-viewer-binding` — binds the `view` ClusterRole to user `demo-viewer` in `rbac-demo`. Read-only access to most resources in this namespace. Cannot modify anything.

Verify the namespace-scoped bindings:

```bash
oc get rolebindings -n rbac-demo | grep demo
```

```
demo-admin-binding    ClusterRole/admin    ...
demo-editor-binding   ClusterRole/edit     ...
demo-viewer-binding   ClusterRole/view     ...
```

Notice that all three namespace-scoped bindings reference a ClusterRole, not a Role. This is the pattern described in Step 1 — the ClusterRole definitions (`admin`, `edit`, `view`) are reusable cluster-wide, but the RoleBinding scopes them to a single namespace.

---

### Step 5: Test the Permission Boundaries

This is where the RBAC model becomes concrete. Log in as each user and observe what they can and cannot do.

**demo-viewer: read-only in one namespace**

```bash
oc login -u demo-viewer -p 'demo1234'
```

```bash
oc get projects
```

```
NAME        DISPLAY NAME   STATUS
rbac-demo                  Active
```

Only one project is visible. Not because other namespaces do not exist — the cluster has dozens of them. The API server simply does not list namespaces where this user has no access.

```bash
oc get pods -n rbac-demo
```

Works. Now try to create something:

```bash
oc run test-pod --image=registry.access.redhat.com/ubi9/ubi-minimal:latest -n rbac-demo
```

```
Error from server (Forbidden): pods is forbidden: User "demo-viewer" cannot create resource "pods" in API group "" in the namespace "rbac-demo"
```

And try to read a different namespace:

```bash
oc get pods -n default
```

```
Error from server (Forbidden): pods is forbidden: User "demo-viewer" cannot list resource "pods" in API group "" in the namespace "default"
```

Read-only in `rbac-demo`, zero access everywhere else. The boundary is structural.

**demo-editor: create and modify, but no RBAC management**

```bash
oc login -u demo-editor -p 'demo1234'
```

```bash
oc run test-pod --image=registry.access.redhat.com/ubi9/ubi-minimal:latest -n rbac-demo
```

Works. The editor can create workloads. Now try to manage RBAC:

```bash
oc auth can-i create rolebindings -n rbac-demo
```

```
no
```

The `edit` role deliberately excludes RBAC management. An editor cannot grant themselves or anyone else additional permissions.

Clean up:

```bash
oc delete pod test-pod -n rbac-demo
```

**demo-admin: full namespace control, including delegation**

```bash
oc login -u demo-admin -p 'demo1234'
```

```bash
oc auth can-i create rolebindings -n rbac-demo
```

```
yes
```

The namespace admin can create RoleBindings — meaning they can delegate access within their namespace without involving a cluster administrator. But watch what happens when they try to go beyond their namespace:

```bash
oc auth can-i create rolebindings -n default
```

```
no
```

```bash
oc auth can-i create clusterrolebindings
```

```
no
```

The admin owns their namespace. They cannot touch anyone else's, and they cannot create cluster-wide grants. The API server also prevents privilege escalation — an admin cannot bind a ClusterRole that they do not hold themselves:

```bash
oc create rolebinding escalation-attempt \
  --clusterrole=cluster-admin \
  --user=demo-viewer \
  -n rbac-demo
```

The API server rejects this because `demo-admin` does not hold `cluster-admin`.

**demo-clusterreader: see everything, change nothing**

```bash
oc login -u demo-clusterreader -p 'demo1234'
```

```bash
oc get pods --all-namespaces | head -10
```

All pods across every namespace are visible. Now try to modify something:

```bash
oc auth can-i delete pods -n rbac-demo
```

```
no
```

Cluster-wide read access with zero write capability.

---

### Step 6: Build a Custom Role

The built-in roles cover most situations, but sometimes you need a role that is more precise. Consider an operator who needs to scale deployments and read logs during an incident, but should not be able to delete anything or access secrets.

Download [6-custom-role.yaml](../posts/openshift-rbac-explained/6-custom-role.yaml) and apply it:

```bash
oc login -u <cluster-admin-user>
oc apply -f 6-custom-role.yaml
```

This creates a `pod-operator` Role in the `rbac-demo` namespace and binds it to `demo-editor`. The Role allows:

- `get`, `list`, `watch`, `update`, `patch` on deployments — the operator can scale workloads and update images
- `get`, `list`, `watch` on pods and pod logs — the operator can see what is running and pull logs

It deliberately excludes `delete` on deployments, any verb on secrets, and any access outside the namespace.

Verify the permissions:

```bash
oc auth can-i update deployments --as=demo-editor -n rbac-demo
```

```
yes
```

```bash
oc auth can-i delete deployments --as=demo-editor -n rbac-demo
```

Check whether `edit` grants delete on deployments (it does — this is a good illustration of why the `edit` ClusterRole might be too broad for some use cases and a custom Role is better):

```bash
oc auth can-i delete deployments --as=demo-editor -n rbac-demo
```

```
yes
```

The `demo-editor` user still has the `edit` ClusterRole as well, which does grant delete. Permissions in RBAC are additive — if any binding grants the action, it is allowed. To restrict the user to only the `pod-operator` permissions, you would remove the `edit` RoleBinding and leave only the custom Role binding. This is the important principle: RBAC can only add permissions, never remove them. Every binding the user has contributes to their effective permissions.

---

### Step 7: Audit Permissions with `oc auth can-i` and `oc adm policy who-can`

Two commands make RBAC auditable at any time.

**oc auth can-i** answers "can this user do this action?" It evaluates the live RBAC state — not a cached report, but the actual authorization decision the API server would make right now.

```bash
oc auth can-i delete pods --as=demo-viewer -n rbac-demo
```

```
no
```

The `--as` flag is impersonation — a cluster-admin capability that lets you test any identity without logging out. Use `--list` to see everything a user can do in a namespace:

```bash
oc auth can-i --list --as=demo-editor -n rbac-demo
```

This outputs the complete permission matrix for that user in that namespace.

**oc adm policy who-can** answers the reverse question: "who can perform this action?" This is indispensable after a production incident.

```bash
oc adm policy who-can delete pods -n rbac-demo
```

This lists every user, group, and service account that can delete pods in the namespace. If someone deleted a pod during an incident and you need to know who could have done it, this command gives you the definitive list against the current RBAC state.

---

## Where To Go From Here

This walkthrough covers the foundation — identity provider configuration, built-in roles, namespace-scoped versus cluster-scoped bindings, custom roles, and auditing. A few topics build directly on top of this:

- **Groups** — binding roles to groups instead of individual users makes onboarding and offboarding a single operation. Adding a user to a group grants permissions; removing them revokes permissions. For any human identity, groups are the right answer.
- **ServiceAccounts** — every CI/CD pipeline, operator, and automation tool should run under a ServiceAccount with a custom Role scoped to exactly what it needs. A deployment pipeline needs `update` on deployments in one namespace — not `cluster-admin`.
- **ResourceQuotas** — RBAC controls who can do what, but not how much. A user with `edit` and no quota could deploy enough pods to starve the cluster. ResourceQuota and LimitRange close that gap.
- **Aggregated ClusterRoles** — when new operators install Custom Resource Definitions, the built-in `view`, `edit`, and `admin` roles do not automatically cover those new resource types. Aggregated ClusterRoles extend the built-in roles with one apply, without touching any existing binding.
