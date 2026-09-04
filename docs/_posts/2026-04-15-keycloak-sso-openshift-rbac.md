---
layout: post
title: "Understanding OpenShift SSO and RBAC by Running Keycloak as an Operator"
date: 2026-04-15
---

Most organizations already have an enterprise SSO — Active Directory, Okta, Azure AD — and connecting OpenShift to it is straightforward once you understand what OpenShift actually expects from an identity provider. Keycloak, installed as an operator on your management cluster, is the fastest way to learn that without touching production infrastructure. This is a quick why and how-to for standing up Keycloak, creating groups and users, and watching how group membership flows through to cluster RBAC.

## Why This Matters

OpenShift does not care whether the identity provider behind its OAuth integration is Keycloak, Okta, or Active Directory Federation Services — as long as it speaks OIDC, OpenShift will talk to it. The mechanism is identical across providers. What differs is configuration: the issuer URL, the client ID, the client secret, and the claims the token carries.

That last point is where most integrations get stuck. Your enterprise SSO does not automatically surface group membership in the token — you have to configure it to include a groups claim, tell OpenShift which claim name to read, and make sure the group names in the token match the Group objects in OpenShift that your RBAC bindings reference. Working through this with Keycloak makes each of those steps concrete. By the end, you know what a correctly configured claim looks like, what breaks when the group name format is wrong, and what questions to bring to your enterprise SSO team when it is time to do this for real.

---

## The Steps

1. Find the correct RHBK operator channel and install the operator in a dedicated namespace
2. Deploy PostgreSQL as Keycloak's backing database
3. Create the Keycloak instance and retrieve the initial admin credentials
4. Create the OpenShift realm, three groups, and one user per group using the admin CLI
5. Create an OpenShift client for each cluster with a groups claim mapper
6. Configure the management cluster OAuth to use Keycloak as its OIDC identity provider
7. Configure the remote cluster with its own Keycloak client and OIDC identity provider
8. Create OpenShift Group objects and ClusterRoleBindings on the remote cluster

---

## How To Do It

### Step 1: Install the RHBK Operator

The Red Hat Build of Keycloak (RHBK) operator is distributed through the `redhat-operators` catalog source. Before subscribing, find the recommended channel — operator channels are versioned by major release and subscribing to a non-existent channel fails silently. The pattern for doing this from the CLI is covered in [How to Find, Install, and Explore an OpenShift Operator from the CLI](/2026/04/06/exploring-openshift-operators.html). For RHBK, start with the default channel:

```bash
oc get packagemanifest rhbk-operator -n openshift-marketplace \
  -o jsonpath='{.status.defaultChannel}'
```

```
stable-v26
```

`stable-v26` is a versioned channel — RHBK follows Keycloak's upstream major version numbering and each major version gets its own channel. Always use the value returned here rather than copying a channel name from a tutorial, including this one. Use that channel to check which operator version you will actually get before subscribing:

```bash
oc get packagemanifest rhbk-operator -n openshift-marketplace \
  -o jsonpath='{range .status.channels[?(@.name=="stable-v26")]}{.currentCSV}{"\n"}{end}'
```

```
rhbk-operator.v26.0.0
```

This is the CSV OLM will install. You will see this name again in the InstallPlan and in the CSV list after the operator is running — it gives you a precise version to verify against.

Give the operator a dedicated namespace and OperatorGroup so OLM scopes it correctly and its InstallPlan is independent of any other operator — the reason for this is covered in [Why you should not install Operators in common namespaces](/2026/04/09/openshift-operators-dedicated-namespaces.html).

Download [keycloak-operator.yaml](/posts/keycloak-sso-openshift-rbac/1-keycloak-operator.yaml) and apply it:

```bash
oc apply -f keycloak-operator.yaml
```

The file contains three resources applied in order. The `Namespace` creates the `keycloak` namespace where all components will run. The `OperatorGroup` scopes the operator's watch to that namespace — without it OLM cannot place the operator and the Subscription stalls with no error message. The `Subscription` is what tells OLM to actually install the operator: `channel` selects the version stream, `source` points at the `redhat-operators` catalog, and `installPlanApproval: Manual` means OLM creates an InstallPlan but waits for your explicit approval before making changes, giving you control over when upgrades happen.

`installPlanApproval: Manual` gives you explicit control over when the operator upgrades. Check for the pending InstallPlan and approve it:

```bash
oc get installplan -n keycloak
```

```
NAME            CSV                   APPROVAL   APPROVED
install-xxxxx   rhbk-operator.v26.0   Manual     false
```

```bash
oc patch installplan install-xxxxx -n keycloak \
  --type merge \
  --patch '{"spec":{"approved":true}}'
```

Wait for the CSV to reach `Succeeded` before proceeding — a running pod does not mean OLM finished reconciling:

```bash
oc get csv -n keycloak -w
```

```
NAME                  DISPLAY                       VERSION   PHASE
rhbk-operator.v26.0   Red Hat Build of Keycloak     26.0.0    Succeeded
```

---

### Step 2: Deploy PostgreSQL

RHBK requires a relational database. Use the Red Hat UBI PostgreSQL image so the stack stays on a supported, consistent base.

Download [keycloak-db-secret.yaml](/posts/keycloak-sso-openshift-rbac/2-keycloak-db-secret.yaml) and update the `password` value before applying — the file contains a placeholder:

```bash
oc apply -f keycloak-db-secret.yaml
```

The secret stores credentials under two keys: `username` and `password`. Both the PostgreSQL StatefulSet (which injects them as environment variables into the container) and the Keycloak CR (which references them by key name to configure its database connection) read from this same secret — one place to manage, two consumers.

Download [keycloak-postgres.yaml](/posts/keycloak-sso-openshift-rbac/3-keycloak-postgres.yaml):

```bash
oc apply -f keycloak-postgres.yaml
```

The file defines two resources. The `StatefulSet` runs a single PostgreSQL replica using the Red Hat UBI image. It reads `POSTGRESQL_USER` and `POSTGRESQL_PASSWORD` from the secret you just created and sets `POSTGRESQL_DATABASE` to `keycloak` — that database name is what the Keycloak CR expects. The `volumeClaimTemplates` section provisions a 10Gi PersistentVolumeClaim per replica; because this is a StatefulSet the PVC survives pod restarts and rescheduling, so your Keycloak data persists across failures. The `Service` exposes PostgreSQL on port 5432 under the DNS name `postgresql` — this is the `host` value the Keycloak CR uses in the next step to find the database.

Confirm PostgreSQL is running and the credentials are valid before Keycloak tries to use them:

```bash
oc get pods -n keycloak -l app=postgresql
```

```
NAME           READY   STATUS    RESTARTS   AGE
postgresql-0   1/1     Running   0          90s
```

```bash
oc exec postgresql-0 -n keycloak -- psql -U keycloak -d keycloak -c '\l'
```

You should see the `keycloak` database listed in the output. A successful connection here means the StatefulSet, the credentials secret, and the network path are all working correctly before you create the Keycloak instance.

---

### Step 3: Create the Keycloak Instance

Download [keycloak-instance.yaml](/posts/keycloak-sso-openshift-rbac/4-keycloak-instance.yaml). Edit the `hostname` field, replacing `<management-cluster-domain>` with the apps domain for your management cluster — the value from `oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.status.domain}'`.

```bash
oc apply -f keycloak-instance.yaml
```

The Keycloak CR has several fields worth understanding before you apply it. The `db` section points Keycloak at the PostgreSQL instance: `host: postgresql` resolves to the Service created in Step 2, and `usernameSecret` and `passwordSecret` pull credentials from the same secret the StatefulSet uses. The `hostname.hostname` field controls what Keycloak uses as its base URL for token issuers and redirect validation — it must match the route hostname exactly, which is why it uses the cluster's apps domain. `http.httpEnabled: true` enables Keycloak to listen on plain HTTP at port 8080 inside the pod, which is what the admin CLI uses in Step 4 to connect on `localhost:8080` without requiring certificate configuration. `startOptimizedImage: false` tells Keycloak to build its full provider configuration at startup rather than assuming a pre-built image — required for a standard operator install. The operator creates a StatefulSet, a Service, and a Route. OpenShift signs the service's TLS certificate using the cluster's internal CA, which the OAuth server trusts natively — you do not need to manually configure certificate trust between the OAuth server and Keycloak.

Watch for the Keycloak resource to become ready:

```bash
oc get keycloak -n keycloak -w
```

```
NAME       READY   STATUS    RESTARTS   AGE
keycloak   True    Running   0          3m
```

Once ready, retrieve the initial admin credentials the operator generated:

```bash
oc get secret keycloak-initial-admin -n keycloak \
  -o jsonpath='{.data.username}' | base64 -d && echo
oc get secret keycloak-initial-admin -n keycloak \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

Confirm the route exists and the admin console is reachable:

```bash
oc get route -n keycloak
```

```
NAME       HOST/PORT                                   TERMINATION   WILDCARD
keycloak   keycloak.apps.<management-cluster-domain>   passthrough   None
```

Open the admin console in your browser at the URL shown and log in with the credentials you retrieved. Leave the tab open — you will need it to verify the realm, groups, and users you are about to create.

---

### Step 4: Create the Realm, Groups, and Users

The `kcadm.sh` admin CLI ships inside the Keycloak container. Running commands from within the pod lets you reach Keycloak on localhost over HTTP without worrying about routing or certificate trust during setup.

```bash
KC_POD=$(oc get pods -n keycloak -l app=keycloak -o jsonpath='{.items[0].metadata.name}')
oc exec -it $KC_POD -n keycloak -- bash
```

The Keycloak container runs as a system user whose home directory may not be writable. Create the config directory before authenticating, otherwise `kcadm.sh` fails to save its session:

```bash
mkdir -p ~/.keycloak
```

Authenticate the admin CLI using the password you retrieved in Step 3:

```bash
/opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 \
  --realm master \
  --user admin \
  --password <admin-password>
```

```
Logging into http://localhost:8080 as user admin of realm master
```

**Create the OpenShift realm.** A realm is Keycloak's top-level organizational boundary — users, groups, clients, and sessions are all scoped to a realm. Creating a dedicated realm for OpenShift keeps it cleanly separated from the master realm. The name you choose here (`openshift` in this walkthrough) appears directly in the issuer URL you configure in Steps 6 and 7 — note it and use it consistently:

```bash
/opt/keycloak/bin/kcadm.sh create realms \
  -s realm=openshift \
  -s enabled=true \
  -s displayName="OpenShift"
```

Verify it exists:

```bash
/opt/keycloak/bin/kcadm.sh get realms --fields realm
```

```json
[ {
  "realm" : "master"
}, {
  "realm" : "openshift"
} ]
```

**Create the three groups.** Groups in Keycloak become group claims in the JWT. OpenShift reads those claims and maps them to Group objects on the cluster — which is what your ClusterRoleBindings reference:

```bash
/opt/keycloak/bin/kcadm.sh create groups -r openshift -s name=admins
/opt/keycloak/bin/kcadm.sh create groups -r openshift -s name=devs
/opt/keycloak/bin/kcadm.sh create groups -r openshift -s name=readers
```

Confirm all three exist and capture their IDs:

```bash
/opt/keycloak/bin/kcadm.sh get groups -r openshift --fields id,name
```

```json
[ {
  "id" : "aaaa-1111-...",
  "name" : "admins"
}, {
  "id" : "bbbb-2222-...",
  "name" : "devs"
}, {
  "id" : "cccc-3333-...",
  "name" : "readers"
} ]
```

**Create one user per group.** The same pattern extends to as many users as you need:

```bash
# Admin user
/opt/keycloak/bin/kcadm.sh create users -r openshift \
  -s username=alice \
  -s email=alice@example.com \
  -s firstName=Alice \
  -s lastName=Admin \
  -s enabled=true

/opt/keycloak/bin/kcadm.sh set-password -r openshift \
  --username alice --new-password change-me-alice

# Developer user
/opt/keycloak/bin/kcadm.sh create users -r openshift \
  -s username=bob \
  -s email=bob@example.com \
  -s firstName=Bob \
  -s lastName=Dev \
  -s enabled=true

/opt/keycloak/bin/kcadm.sh set-password -r openshift \
  --username bob --new-password change-me-bob

# Reader user
/opt/keycloak/bin/kcadm.sh create users -r openshift \
  -s username=carol \
  -s email=carol@example.com \
  -s firstName=Carol \
  -s lastName=Reader \
  -s enabled=true

/opt/keycloak/bin/kcadm.sh set-password -r openshift \
  --username carol --new-password change-me-carol
```

**Assign users to their groups.** Pull the user and group IDs, then create the memberships:

```bash
ALICE_ID=$(/opt/keycloak/bin/kcadm.sh get users -r openshift \
  -q username=alice --fields id | jq -r '.[0].id')
BOB_ID=$(/opt/keycloak/bin/kcadm.sh get users -r openshift \
  -q username=bob --fields id | jq -r '.[0].id')
CAROL_ID=$(/opt/keycloak/bin/kcadm.sh get users -r openshift \
  -q username=carol --fields id | jq -r '.[0].id')

ADMINS_ID=$(/opt/keycloak/bin/kcadm.sh get groups -r openshift \
  --fields id,name | jq -r '.[] | select(.name=="admins") | .id')
DEVS_ID=$(/opt/keycloak/bin/kcadm.sh get groups -r openshift \
  --fields id,name | jq -r '.[] | select(.name=="devs") | .id')
READERS_ID=$(/opt/keycloak/bin/kcadm.sh get groups -r openshift \
  --fields id,name | jq -r '.[] | select(.name=="readers") | .id')

/opt/keycloak/bin/kcadm.sh update users/$ALICE_ID/groups/$ADMINS_ID \
  -r openshift -s realm=openshift -s userId=$ALICE_ID -s groupId=$ADMINS_ID -n
/opt/keycloak/bin/kcadm.sh update users/$BOB_ID/groups/$DEVS_ID \
  -r openshift -s realm=openshift -s userId=$BOB_ID -s groupId=$DEVS_ID -n
/opt/keycloak/bin/kcadm.sh update users/$CAROL_ID/groups/$READERS_ID \
  -r openshift -s realm=openshift -s userId=$CAROL_ID -s groupId=$READERS_ID -n
```

Verify the membership for each user:

```bash
/opt/keycloak/bin/kcadm.sh get users/$ALICE_ID/groups -r openshift --fields name
```

```json
[ {
  "name" : "admins"
} ]
```

Repeat for `$BOB_ID` and `$CAROL_ID` to confirm `devs` and `readers` respectively.

---

### Step 5: Create Keycloak Clients and Configure the Groups Claim Mapper

Each OpenShift cluster authenticates to Keycloak using its own client — a client ID and secret pair that Keycloak uses to identify which application is requesting authentication. Stay inside the Keycloak pod for these commands.

**Create the management cluster client:**

```bash
/opt/keycloak/bin/kcadm.sh create clients -r openshift \
  -s clientId=openshift-management \
  -s enabled=true \
  -s protocol=openid-connect \
  -s publicClient=false \
  -s 'redirectUris=["https://oauth-openshift.apps.<management-cluster-domain>/oauth2callback/keycloak"]'
```

**Create the remote cluster client:**

```bash
/opt/keycloak/bin/kcadm.sh create clients -r openshift \
  -s clientId=openshift-remote \
  -s enabled=true \
  -s protocol=openid-connect \
  -s publicClient=false \
  -s 'redirectUris=["https://oauth-openshift.apps.<remote-cluster-domain>/oauth2callback/keycloak"]'
```

The redirect URI format is always `https://oauth-openshift.apps.<cluster-domain>/oauth2callback/<idp-name>`. The `<idp-name>` segment must exactly match the `name:` field you set in the cluster's OAuth configuration in the next step. In this walkthrough that name is `keycloak` — if you use a different name, update the redirect URI in the client to match before proceeding, otherwise the OAuth callback will be rejected.

**Retrieve the client secrets.** You will need these values in Steps 6 and 7:

```bash
MGMT_CLIENT_ID=$(/opt/keycloak/bin/kcadm.sh get clients -r openshift \
  -q clientId=openshift-management --fields id | jq -r '.[0].id')
REMOTE_CLIENT_ID=$(/opt/keycloak/bin/kcadm.sh get clients -r openshift \
  -q clientId=openshift-remote --fields id | jq -r '.[0].id')

/opt/keycloak/bin/kcadm.sh get clients/$MGMT_CLIENT_ID/client-secret -r openshift
/opt/keycloak/bin/kcadm.sh get clients/$REMOTE_CLIENT_ID/client-secret -r openshift
```

```json
{
  "type" : "secret",
  "value" : "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
}
```

Note both values. These are the `clientSecret` values you store in OpenShift secrets in the following steps.

**Add the groups claim mapper to both clients.** Without this mapper, Keycloak issues tokens that contain no group membership information. OpenShift cannot populate group bindings from a token with no groups claim — this is the step most configurations get wrong:

```bash
for CLIENT_ID in $MGMT_CLIENT_ID $REMOTE_CLIENT_ID; do
  /opt/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/protocol-mappers/models \
    -r openshift \
    -s name=groups \
    -s protocol=openid-connect \
    -s protocolMapper=oidc-group-membership-mapper \
    -s 'config."full.path"=false' \
    -s 'config."id.token.claim"=true' \
    -s 'config."access.token.claim"=true' \
    -s 'config."userinfo.token.claim"=true' \
    -s 'config."claim.name"=groups'
done
```

`full.path=false` tells Keycloak to include the short group name (`admins`) rather than the full path (`/admins`). OpenShift Group names match the short form — if you leave this at `true`, the group names in the token will not match the Group objects on the cluster.

Verify the mapper was created:

```bash
/opt/keycloak/bin/kcadm.sh get clients/$MGMT_CLIENT_ID/protocol-mappers/models \
  -r openshift --fields name,protocolMapper
```

```json
[ {
  "name" : "groups",
  "protocolMapper" : "oidc-group-membership-mapper"
} ]
```

Exit the pod shell before continuing:

```bash
exit
```

---

### Step 6: Configure the Management Cluster OAuth

Back on your local machine with access to the management cluster, create the secret containing the client secret you retrieved for `openshift-management`:

```bash
oc create secret generic keycloak-management-secret \
  --from-literal=clientSecret=<management-client-secret> \
  -n openshift-config
```

Download [management-oauth-patch.yaml](/posts/keycloak-sso-openshift-rbac/5-management-oauth-patch.yaml). Edit the `issuer` field, replacing `<management-cluster-domain>` with your actual apps domain. Then patch the cluster OAuth object:

```bash
oc patch oauth cluster --type merge --patch-file management-oauth-patch.yaml
```

The patch adds one entry to the cluster's `identityProviders` list. `name: keycloak` is the label users see on the login page — it must also match the `<idp-name>` segment in the redirect URI registered in the Keycloak client. `mappingMethod: claim` tells OpenShift to derive the username from a claim in the token rather than looking the user up in a separate store. `type: OpenID` selects the OIDC flow. Under `openID`: `clientID` identifies the Keycloak client you created in Step 5; `clientSecret.name` references the secret you just created; `issuer` is the Keycloak realm URL — OpenShift fetches the OIDC discovery document from this URL to find token signing keys and endpoint locations. The `claims` block maps token fields to OpenShift identity attributes: `preferredUsername` becomes the OpenShift username, `name` and `email` populate the user's display name and email, and `groups` is the claim that carries group membership from Keycloak — this is what allows OpenShift to populate Group objects automatically on login.

The `authentication-operator` detects the change and rolls out new OAuth pods. Wait for the rollout to complete before testing:

```bash
oc rollout status deployment/oauth-openshift -n openshift-authentication
```

```
deployment "oauth-openshift" successfully rolled out
```

**Validate the login.** Navigate to the OpenShift console at `https://console-openshift-console.apps.<management-cluster-domain>`. You should see a `keycloak` identity provider option alongside any existing providers. Log in as `alice`. After authentication, use the "Copy login command" link in the top-right corner to get a token-based `oc login` command. Run it in your terminal, then verify the resulting identity and group:

```bash
oc whoami
```

```
alice
```

```bash
oc get groups
```

```
NAME      USERS
admins    alice
```

OpenShift created the `admins` Group and added `alice` to it based on the groups claim in her Keycloak token. No manual group creation was required — the OAuth server does this automatically on first login. Log out of the Keycloak session in your browser and log back in to your cluster admin account before proceeding.

---

### Step 7: Configure the Remote Cluster OAuth

Log into your remote cluster:

```bash
oc login https://api.<remote-cluster-domain>:6443
```

The remote cluster's OAuth server contacts Keycloak's OIDC discovery endpoint at `https://keycloak.apps.<management-cluster-domain>/realms/<realm-name>/.well-known/openid-configuration` when a user authenticates — replace `<realm-name>` with the realm you created in Step 4. Confirm this URL is reachable from the remote cluster's network before applying the configuration — a timeout here surfaces as a confusing login failure later.

Create the client secret for the remote cluster:

```bash
oc create secret generic keycloak-remote-secret \
  --from-literal=clientSecret=<remote-client-secret> \
  -n openshift-config
```

Apply the OIDC identity provider configuration. Download [remote-oauth-patch.yaml](/posts/keycloak-sso-openshift-rbac/6-remote-oauth-patch.yaml) — the structure is identical to the management cluster patch. The `issuer` points at the same Keycloak instance on the management cluster because both clusters trust the same identity provider. Only `clientID` and `clientSecret` differ, reflecting the separate client you registered for this cluster in Step 5. Edit the `issuer` field with your management cluster's apps domain, then apply:

```bash
oc patch oauth cluster --type merge --patch-file remote-oauth-patch.yaml
```

```bash
oc rollout status deployment/oauth-openshift -n openshift-authentication
```

---

### Step 8: Create Group RBAC Bindings on the Remote Cluster

OpenShift populates the Group objects from Keycloak tokens automatically on first login. You can wait for users to log in, or pre-create the Group objects so that RBAC bindings are active immediately — before anyone has authenticated. Pre-creating them is the right approach when handing a cluster to a team: the permissions are ready the moment the first user arrives.

```bash
oc adm groups new admins
oc adm groups new devs
oc adm groups new readers
```

When users log in, OpenShift merges their token's group memberships into these pre-existing Group objects.

Create the ClusterRoleBindings. These three bindings map each group to a built-in ClusterRole that matches their intended access level:

- `admins` → `cluster-admin`: full cluster control, appropriate for the platform team
- `devs` → `edit`: create and manage workloads but not RBAC or cluster-scoped resources
- `readers` → `view`: read-only across all namespaces, no mutation rights

Download [remote-rbac.yaml](/posts/keycloak-sso-openshift-rbac/7-remote-rbac.yaml), which defines all three ClusterRoleBindings:

```bash
oc apply -f remote-rbac.yaml
```

Each ClusterRoleBinding has two halves. `subjects` lists who the binding applies to — here a `Group` kind, so the binding grants permissions to every user who arrives with that group name in their Keycloak token. `roleRef` names the ClusterRole that defines the actual permissions. The three built-in ClusterRoles cover the common access patterns without requiring custom role definitions: `cluster-admin` is unrestricted cluster access; `edit` allows creating and managing workloads but not touching RBAC or cluster-scoped resources; `view` is read-only across all namespaces with no mutation rights. If your team needs tighter boundaries — for example, `devs` scoped to specific namespaces rather than cluster-wide — replace the `ClusterRoleBinding` with a namespace-scoped `RoleBinding` referencing the same `edit` ClusterRole.

**Validate the bindings.** OpenShift requires both `--as` and `--as-group` to be set together when using group impersonation — `--as-group` alone is rejected. Use the usernames from Step 4 as the `--as` value. The authorization check evaluates the group binding rules regardless of whether that user has logged in yet:

```bash
# admins can do anything
oc auth can-i '*' '*' --all-namespaces --as=alice --as-group=admins
```

```
yes
```

```bash
# devs can create workloads
oc auth can-i create deployments --as=bob --as-group=devs -n default
```

```
yes
```

```bash
# devs cannot escalate privileges
oc auth can-i create clusterrolebindings --as=bob --as-group=devs
```

```
no
```

```bash
# readers can view but not change anything
oc auth can-i get pods --as=carol --as-group=readers -n default
```

```
yes
```

```bash
oc auth can-i delete pods --as=carol --as-group=readers -n default
```

```
no
```

All four checks confirm the bindings are working as expected. Log in as `bob` through the remote cluster's console to confirm end-to-end: his Keycloak token includes `devs` in the groups claim, OpenShift adds him to the `devs` Group, and the `keycloak-devs` ClusterRoleBinding gives him `edit` access on the cluster.

At this point you have seen the full integration: a user authenticates against Keycloak, the token carries a groups claim, OpenShift reads it, and RBAC follows automatically. That chain — IDP issues token with groups, OpenShift maps groups to bindings — is identical when your enterprise SSO is on the other end. The YAML in Steps 6 and 7 does not change structurally. You swap the `issuer`, the `clientID`, and the `clientSecret` for the values your enterprise IDP provides, and confirm that the groups claim in its tokens matches the Group names you bind in OpenShift. Everything else you have already done here.

---

## What You Built

By the end of this walkthrough you have a working SSO integration spanning two OpenShift clusters, backed by Keycloak running as an operator on your management cluster.

| Component | What it does |
|---|---|
| RHBK operator + PostgreSQL | Runs Keycloak in your cluster with a persistent, supported backing store |
| OpenShift realm | Isolates your cluster identities from Keycloak's master realm |
| Groups: `admins`, `devs`, `readers` | Three role archetypes — users belong to groups, not individual bindings |
| Users: `alice`, `bob`, `carol` | One representative user per group to verify end-to-end flow |
| Groups claim mapper | Embeds group membership in every JWT so OpenShift can read it |
| Keycloak clients (one per cluster) | Separate OIDC credentials scoped to each cluster's redirect URI |
| OAuth configuration (both clusters) | Tells each cluster to trust Keycloak and which claims to read |
| ClusterRoleBindings on remote cluster | Maps `admins` → `cluster-admin`, `devs` → `edit`, `readers` → `view` |

The key insight from building this is the claims chain: Keycloak issues a token, the token contains a `groups` claim, OpenShift reads that claim and maps it to Group objects, Group objects are what RBAC bindings reference. Every piece of that chain is explicit and configurable. When you connect your enterprise SSO, you are configuring the same chain — only the issuer URL and credential values change.

---

## References

- [RHBK Operator Documentation](https://docs.redhat.com/en/documentation/red_hat_build_of_keycloak)
- [OCP Docs: Configuring an OpenID Connect identity provider](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/authentication_and_authorization/configuring-identity-providers#configuring-oidc-identity-provider)
- [OCP Docs: Understanding RBAC](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/authentication_and_authorization/using-rbac)
- [How to Find, Install, and Explore an OpenShift Operator from the CLI](/2026/04/06/exploring-openshift-operators.html)
- [Why you should not install Operators in common namespaces](/2026/04/09/openshift-operators-dedicated-namespaces.html)
