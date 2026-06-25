# Installation Guide: check_k8s_pods

## Table of Contents

- Requirements
- Plugin Installation
- Kubernetes RBAC
- Method 1: Config File Deployment
  - CheckCommand Definition
  - Host Template
  - Service Definition
- Method 2: Icinga Director (UI)
  - Create CheckCommand
  - Create Host Template
  - Create Service
- Verification
- Troubleshooting

## Requirements

- Icinga 2 >= 2.13.0
- Python >= 3.8
- Python package `kubernetes` (>= 24.2.0)
- A kubeconfig file *or* an API URL + Bearer token reachable from the Icinga
  node executing the check

## Plugin Installation

```bash
cp check_k8s_pods.py /usr/lib64/nagios/plugins/check_k8s_pods
chmod +x /usr/lib64/nagios/plugins/check_k8s_pods
```

> **Plugin path:** these examples use the AlmaLinux 9 path `/usr/lib64/nagios/plugins`
> (the 64-bit RHEL-family `PluginDir`). On Debian/Ubuntu it is `/usr/lib/nagios/plugins`
> — confirm your distribution's `PluginDir` constant and adjust the paths accordingly.

Install the Python client. Prefer a system package where available:

```bash
# Debian/Ubuntu
apt-get install python3-kubernetes

# RHEL/Rocky 9
dnf install python3-kubernetes

# Otherwise pip (in a venv shared with other Icinga Python plugins is fine)
pip install -r requirements.txt
```

Run the plugin from the node that has network reachability to the target
Kubernetes API. For monitoring a remote cluster, that is usually the Icinga
master or satellite.

## Kubernetes RBAC

This section is the canonical RBAC setup for all three `check_k8s_*` plugins.
Configure it once and reuse the same ServiceAccount + token for
`check_k8s_workloads` and `check_k8s_nodes`.

### Required Permissions

| Plugin                | API Group | Resource     | Verb | Scope          |
|-----------------------|-----------|--------------|------|----------------|
| check_k8s_pods        | `""`      | `pods`       | list | namespace(s) or cluster-wide |
| check_k8s_workloads   | `apps`    | `deployments`   | list | namespace(s) or cluster-wide |
| check_k8s_workloads   | `apps`    | `statefulsets`  | list | namespace(s) or cluster-wide |
| check_k8s_nodes       | `""`      | `nodes`      | list | **cluster-wide only** (nodes are cluster-scoped) |

> The default `view` ClusterRole grants pods / deployments / statefulsets but
> **does not** grant access to `nodes`. The custom ClusterRole below grants
> exactly what the three plugins need — nothing more.

### Prerequisites

- `kubectl` configured against the target cluster with permission to create
  ServiceAccounts, ClusterRoles, ClusterRoleBindings, and Secrets in
  `kube-system` (cluster-admin or equivalent).
- Decide on a namespace for the ServiceAccount. `kube-system` is conventional
  for cluster-scoped monitoring; a dedicated namespace (e.g. `monitoring`)
  is also fine — the ClusterRoleBinding works regardless.

### Step 1 — Create the ServiceAccount

```bash
kubectl create serviceaccount icinga-readonly -n kube-system
```

Or declaratively (recommended — easier to put under config management):

```yaml
# icinga-rbac.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: icinga-readonly
  namespace: kube-system
```

### Step 2 — Create the ClusterRole

```yaml
# icinga-rbac.yaml (continued)
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: icinga-readonly
rules:
  - apiGroups: [""]
    resources: ["pods", "nodes"]
    verbs: ["list"]
  - apiGroups: ["apps"]
    resources: ["deployments", "statefulsets"]
    verbs: ["list"]
```

> If you only deploy `check_k8s_pods` and `check_k8s_workloads` (no node
> monitoring) you can drop `nodes` from the first rule and bind the built-in
> `view` ClusterRole instead. The custom role above is required as soon as
> `check_k8s_nodes` is in scope.

### Step 3 — Bind the ClusterRole to the ServiceAccount

```yaml
# icinga-rbac.yaml (continued)
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: icinga-readonly
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: icinga-readonly
subjects:
  - kind: ServiceAccount
    name: icinga-readonly
    namespace: kube-system
```

Apply all three objects:

```bash
kubectl apply -f icinga-rbac.yaml
```

### Step 4 — Create a long-lived token Secret

Kubernetes >= 1.24 does **not** auto-create token Secrets for ServiceAccounts.
The short-lived `kubectl create token` flow returns a token that expires after
~1 hour, which is unsuitable for an Icinga check that runs every minute.
Create an explicit `kubernetes.io/service-account-token` Secret to get a
non-expiring token:

```yaml
# icinga-token.yaml
apiVersion: v1
kind: Secret
metadata:
  name: icinga-readonly-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: icinga-readonly
type: kubernetes.io/service-account-token
```

```bash
kubectl apply -f icinga-token.yaml
```

The controller will populate `data.token` and `data.ca.crt` within a few seconds.

### Step 5 — Verify the binding works

Before exporting the token, confirm RBAC is correctly wired up with
`kubectl auth can-i`:

```bash
kubectl auth can-i list pods         --as=system:serviceaccount:kube-system:icinga-readonly -A
kubectl auth can-i list deployments  --as=system:serviceaccount:kube-system:icinga-readonly -A
kubectl auth can-i list statefulsets --as=system:serviceaccount:kube-system:icinga-readonly -A
kubectl auth can-i list nodes        --as=system:serviceaccount:kube-system:icinga-readonly
```

All four commands should print `yes`. If any prints `no`, the ClusterRole rule
list is incomplete or the ClusterRoleBinding references the wrong subject.

### Step 6 — Extract the token and CA certificate

On the Icinga host (or anywhere with `kubectl` access), prepare the target
directory and extract both values:

```bash
mkdir -p /etc/icinga2/k8s

# The directory MUST be group-owned by the Icinga group so the daemon can
# traverse into it. A missing chown on the directory is the most common cause
# of: "API error: ... PermissionError(13, 'Permission denied')" when the
# plugin runs.
chown root:icinga /etc/icinga2/k8s
chmod 0750         /etc/icinga2/k8s

kubectl -n kube-system get secret icinga-readonly-token \
  -o jsonpath='{.data.token}' | base64 -d > /etc/icinga2/k8s/prod.token

kubectl -n kube-system get secret icinga-readonly-token \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > /etc/icinga2/k8s/prod-ca.crt

chown root:icinga /etc/icinga2/k8s/prod.token /etc/icinga2/k8s/prod-ca.crt
chmod 0640         /etc/icinga2/k8s/prod.token /etc/icinga2/k8s/prod-ca.crt

# On Debian/Ubuntu the Icinga 2 daemon historically runs as 'nagios:nagios'.
# If `id icinga` returns "no such user" on your host, substitute 'nagios'
# everywhere above.
```

Verify the running user can actually read both files before continuing:

```bash
sudo -u icinga test -r /etc/icinga2/k8s/prod-ca.crt && echo "ca readable"
sudo -u icinga test -r /etc/icinga2/k8s/prod.token  && echo "token readable"
```

Both `echo` lines must print. If either is silent, re-check ownership of the
**directory** (`stat /etc/icinga2/k8s`) — `0750 root:root` will block the
icinga user even when the files themselves look correct.

The API server URL is whatever `kubectl cluster-info` reports for the control
plane endpoint:

```bash
kubectl cluster-info | head -1
# Kubernetes control plane is running at https://kube-api.prod.example.com:6443
```

### Step 7 — Test the token end-to-end

Confirm the credentials work outside of Icinga before wiring them into a
service definition:

```bash
API_URL="https://kube-api.prod.example.com:6443"
TOKEN="$(cat /etc/icinga2/k8s/prod.token)"

curl --cacert /etc/icinga2/k8s/prod-ca.crt \
     -H "Authorization: Bearer ${TOKEN}" \
     "${API_URL}/api/v1/nodes?limit=1"
```

A `200 OK` JSON response confirms the SA, role, binding, token, and CA cert
are all wired up correctly.

You can also test the plugin directly:

```bash
/usr/lib64/nagios/plugins/check_k8s_pods \
  --api-url "${API_URL}" \
  --token "${TOKEN}" \
  --ca-cert /etc/icinga2/k8s/prod-ca.crt \
  --exclude-namespace kube-system
```

### Option A — kubeconfig instead of raw token

Some operators prefer a single kubeconfig file over separate token + CA paths.
Build one from the values extracted in Step 6:

```bash
API_URL="https://kube-api.prod.example.com:6443"

kubectl config set-cluster prod \
  --server="${API_URL}" \
  --certificate-authority=/etc/icinga2/k8s/prod-ca.crt \
  --embed-certs=true \
  --kubeconfig=/etc/icinga2/k8s/prod.kubeconfig

kubectl config set-credentials icinga-readonly \
  --token="$(cat /etc/icinga2/k8s/prod.token)" \
  --kubeconfig=/etc/icinga2/k8s/prod.kubeconfig

kubectl config set-context prod \
  --cluster=prod --user=icinga-readonly \
  --kubeconfig=/etc/icinga2/k8s/prod.kubeconfig

kubectl config use-context prod \
  --kubeconfig=/etc/icinga2/k8s/prod.kubeconfig

chmod 0640 /etc/icinga2/k8s/prod.kubeconfig
chown root:nagios /etc/icinga2/k8s/prod.kubeconfig
```

Then point the plugin at the kubeconfig:

```bash
/usr/lib64/nagios/plugins/check_k8s_pods --kubeconfig /etc/icinga2/k8s/prod.kubeconfig
```

### Option B — Restrict scope to specific namespaces

If you only want Icinga to see selected namespaces, replace the cluster-wide
ClusterRoleBinding with a namespace-scoped RoleBinding per namespace. Note
this is **incompatible with `check_k8s_nodes`** (nodes are cluster-scoped):

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: icinga-readonly
  namespace: production
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["list"]
  - apiGroups: ["apps"]
    resources: ["deployments", "statefulsets"]
    verbs: ["list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: icinga-readonly
  namespace: production
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: icinga-readonly
subjects:
  - kind: ServiceAccount
    name: icinga-readonly
    namespace: kube-system
```

Then invoke the plugin with `-n production` to match the granted scope.

### Token rotation

A token Secret created in Step 4 is valid until you delete the Secret.
To rotate:

```bash
kubectl -n kube-system delete secret icinga-readonly-token
kubectl apply -f icinga-token.yaml   # re-create
# Re-run Step 6 to refresh the token file on the Icinga host
```

Icinga checks pick up the new token on the next check execution — no Icinga
restart needed.

## Method 1: Config File Deployment

### CheckCommand Definition

```bash
cp icinga2/checkcommand.conf /etc/icinga2/conf.d/check_k8s_pods_command.conf
```

See [icinga2/checkcommand.conf](icinga2/checkcommand.conf) for full contents.

### Host Template

The same template is shared by all three `check_k8s_*` plugins. Install once:

```bash
cp icinga2/host_template.conf /etc/icinga2/conf.d/check_k8s_host_template.conf
```

See [icinga2/host_template.conf](icinga2/host_template.conf) for full contents.

### Service Definition

```bash
cp icinga2/service.conf /etc/icinga2/conf.d/check_k8s_pods_service.conf
```

See [icinga2/service.conf](icinga2/service.conf) for full contents.

On each cluster host object, set the auth vars and enable the check:

```icinga2
object Host "prod-cluster" {
  import "kubernetes-cluster"

  // Option A: kubeconfig
  vars.check_k8s_kubeconfig = "/etc/icinga2/k8s/prod.kubeconfig"

  // Option B: token + API URL
  // vars.check_k8s_api_url = "https://kube-api.prod.example.com:6443"
  // vars.check_k8s_token   = "<bearer-token>"
  // vars.check_k8s_ca_cert = "/etc/icinga2/k8s/prod-ca.crt"

  vars.check_k8s_pods_exclude_namespaces = [ "kube-system" ]
}
```

Validate and reload Icinga 2:

```bash
icinga2 daemon --validate
systemctl reload icinga2
```

## Method 2: Icinga Director (UI)

Assumes Icinga Director is installed and Kickstart wizard completed.
Minimum supported Director version: 1.10.0

### Create CheckCommand

1. Navigate to **Icinga Director > Commands > External Commands**
2. Click **+ Add**
3. Fill in:

   ```
   Name:        check_k8s_pods
   Command:     $USER1$/check_k8s_pods
   Description: Alerts on Kubernetes pod health
   ```

4. Switch to **Arguments** tab and add (only the ones you intend to set):

   | Argument               | Value                                          | Repeat key | Set if                      | Required |
   |------------------------|------------------------------------------------|------------|-----------------------------|----------|
   | `--kubeconfig`         | `$check_k8s_kubeconfig$`                       | No         |                             | No       |
   | `--context`            | `$check_k8s_context$`                          | No         |                             | No       |
   | `--api-url`            | `$check_k8s_api_url$`                          | No         |                             | No       |
   | `--token`              | `$check_k8s_token$`                            | No         |                             | No       |
   | `--ca-cert`            | `$check_k8s_ca_cert$`                          | No         |                             | No       |
   | `--insecure`           |                                                | No         | `$check_k8s_insecure$`      | No       |
   | `-n`                   | `$check_k8s_pods_namespaces$`                  | Yes        |                             | No       |
   | `--exclude-namespace`  | `$check_k8s_pods_exclude_namespaces$`          | Yes        |                             | No       |
   | `-l`                   | `$check_k8s_pods_selector$`                    | No         |                             | No       |
   | `-w`                   | `$check_k8s_pods_restart_warning$`             | No         |                             | No       |
   | `-c`                   | `$check_k8s_pods_restart_critical$`            | No         |                             | No       |
   | `--pending-grace`      | `$check_k8s_pods_pending_grace$`               | No         |                             | No       |
   | `-t`                   | `$check_k8s_pods_timeout$`                     | No         |                             | No       |
   | `-v`                   |                                                | No         | `$check_k8s_pods_verbose$`  | No       |

5. Click **Store** then **Deploy**

### Create Host Template

1. Navigate to **Icinga Director > Hosts > Host Templates**
2. Click **+ Add**
3. Fill in:

   ```
   Name:          kubernetes-cluster
   Check command: hostalive
   ```

4. Switch to **Custom Properties** tab and add:

   ```
   check_k8s_pods                    = true
   check_k8s_kubeconfig              = (optional, leave blank for token auth)
   check_k8s_api_url                 = (optional, leave blank for kubeconfig)
   check_k8s_token                   = (data field, type String, secret)
   check_k8s_ca_cert                 = (optional)
   check_k8s_insecure                = false
   check_k8s_pods_restart_warning    = 5
   check_k8s_pods_restart_critical   = 20
   check_k8s_pods_pending_grace      = 300
   check_k8s_pods_timeout            = 30
   ```

5. Click **Store**

### Create Service

1. Navigate to **Icinga Director > Services > Apply Rules**
2. Click **+ Add**
3. Fill in:

   ```
   Name:          check_k8s_pods
   Check command: check_k8s_pods
   ```

4. Switch to **Assign** tab and add rule:
   - `host.vars.check_k8s_pods` is `true`
   - or: `host.templates` contains `kubernetes-cluster`

5. Click **Store** then **Deploy**

Always trigger a **Deploy** after changes in Director.

**Secrets:** the bearer token is a credential. In Director, create a Data Field
of type String marked as secret and bind it to `check_k8s_token`. In plain
config, keep it in `/etc/icinga2/conf.d/secrets.conf` (already excluded by
this repository's `.gitignore`) with `0600` ownership.

## Verification

```bash
/usr/lib64/nagios/plugins/check_k8s_pods \
  --kubeconfig /etc/icinga2/k8s/prod.kubeconfig \
  --exclude-namespace kube-system
```

Expected output (healthy cluster):

```
check_k8s_pods OK - All 42 pod(s) healthy | pods_total=42 pods_ok=42 pods_warning=0;;;0 pods_critical=0;;;0 max_restarts=2;5;20;0
```

```bash
icinga2 object list --type Service --name "check_k8s_pods"
journalctl -u icinga2 -f
```

## Troubleshooting

### `API error: ... SSLError(PermissionError(13, 'Permission denied'))`

The plugin can't `open(2)` the CA cert file passed to `--ca-cert` (or the CA
embedded in the kubeconfig). This is a Linux filesystem permission error, not
a TLS or Kubernetes error.

Reproduce as the Icinga user:

```bash
sudo -u icinga cat /etc/icinga2/k8s/prod-ca.crt > /dev/null
```

If that fails with "Permission denied", fix ownership of **both** the
directory and the file:

```bash
chown root:icinga /etc/icinga2/k8s /etc/icinga2/k8s/prod-ca.crt /etc/icinga2/k8s/prod.token
chmod 0750         /etc/icinga2/k8s
chmod 0640         /etc/icinga2/k8s/prod-ca.crt /etc/icinga2/k8s/prod.token
```

The most common cause is a missing `chown` on the directory: a file that is
`0640 root:icinga` is unreadable if its parent directory is `0750 root:root`,
because the icinga user cannot traverse into it.

### `API error: ... HTTPSConnectionPool ... certificate verify failed`

The CA cert does not match the API server's serving cert. Re-extract from the
SA token Secret (`data.ca\.crt`) — do not reuse a kubeconfig CA from a
different cluster or a stale cert.

### `403 Forbidden` from the API

The ServiceAccount lacks `list` on one of `pods` / `deployments` / `statefulsets`
/ `nodes`. Re-run the verification step:

```bash
kubectl auth can-i list pods --as=system:serviceaccount:kube-system:icinga-readonly -A
```

If it prints `no`, the ClusterRole or ClusterRoleBinding is misconfigured.

### `401 Unauthorized` from the API

The token is invalid, expired, or was not extracted correctly. Re-run Step 6.
Note that `kubectl create token <sa>` produces a short-lived token (~1 hour)
that is **not suitable** for an Icinga check — you must create the long-lived
`kubernetes.io/service-account-token` Secret from Step 4.

### Plugin returns `UNKNOWN - timed out after 30s`

The API server is unreachable from the Icinga host, or DNS resolution is slow.
Test connectivity directly:

```bash
curl --max-time 5 -k https://<api-host>:6443/version
```

Raise `-t` / `vars.check_k8s_pods_timeout` if your API server is legitimately
slow under load, but first rule out network/firewall issues.
