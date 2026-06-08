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

## Requirements

- Icinga 2 >= 2.13.0
- Python >= 3.8
- Python package `kubernetes` (>= 24.2.0)
- A kubeconfig file *or* an API URL + Bearer token reachable from the Icinga
  node executing the check

## Plugin Installation

```bash
cp check_k8s_pods.py /usr/lib/nagios/plugins/check_k8s_pods
chmod +x /usr/lib/nagios/plugins/check_k8s_pods
```

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

The plugin only needs `list` on `pods` cluster-wide (or on each namespace
passed via `-n`). The built-in `view` ClusterRole is sufficient.

Minimal example: dedicated ServiceAccount with read-only access cluster-wide.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: icinga-readonly
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: icinga-readonly-view
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: view
subjects:
  - kind: ServiceAccount
    name: icinga-readonly
    namespace: kube-system
```

Extract a long-lived token (Kubernetes >= 1.24 does not auto-create token
Secrets — create one explicitly):

```yaml
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
kubectl -n kube-system get secret icinga-readonly-token \
  -o jsonpath='{.data.token}' | base64 -d
kubectl -n kube-system get secret icinga-readonly-token \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > /etc/icinga2/k8s/ca.crt
```

Store the token and CA cert under `/etc/icinga2/k8s/` with `0600` and owned by
the `nagios`/`icinga` user.

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
/usr/lib/nagios/plugins/check_k8s_pods \
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
