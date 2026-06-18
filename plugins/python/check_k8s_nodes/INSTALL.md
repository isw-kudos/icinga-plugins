# Installation Guide: check_k8s_nodes

## Table of Contents

- Requirements
- Plugin Installation
- Kubernetes RBAC
- Method 1: Config File Deployment
  - CheckCommand Definition
  - Service Definition
- Method 2: Icinga Director (UI)
  - Create CheckCommand
  - Reuse Host Template
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
cp check_k8s_nodes.py /usr/lib/nagios/plugins/check_k8s_nodes
chmod +x /usr/lib/nagios/plugins/check_k8s_nodes
```

The same `kubernetes` Python package satisfies all three k8s checks — see
`check_k8s_pods/INSTALL.md` for distro-specific install instructions.

## Kubernetes RBAC

The plugin needs `list` on `nodes` (cluster-scoped). Note that the built-in
`view` ClusterRole does **not** grant access to `nodes` — a custom ClusterRole
is required.

See [`check_k8s_pods/INSTALL.md`](../check_k8s_pods/INSTALL.md#kubernetes-rbac)
for the canonical RBAC setup. The custom `icinga-readonly` ClusterRole in
Step 2 of that guide already includes the `nodes` list permission, so if you
followed it for `check_k8s_pods` you can reuse the same ServiceAccount and
token here unchanged.

If you only want to deploy `check_k8s_nodes` standalone, the minimum is:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: icinga-nodes-readonly
rules:
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["list"]
```

…plus a ServiceAccount, ClusterRoleBinding, and long-lived token Secret as
described in Steps 1, 3, and 4 of `check_k8s_pods/INSTALL.md`.

## Method 1: Config File Deployment

### CheckCommand Definition

```bash
cp icinga2/checkcommand.conf /etc/icinga2/conf.d/check_k8s_nodes_command.conf
```

See [icinga2/checkcommand.conf](icinga2/checkcommand.conf) for full contents.

### Service Definition

```bash
cp icinga2/service.conf /etc/icinga2/conf.d/check_k8s_nodes_service.conf
```

See [icinga2/service.conf](icinga2/service.conf) for full contents.

The shared `kubernetes-cluster` host template installed alongside
`check_k8s_pods` already enables this service via
`vars.check_k8s_nodes = true`.

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
   Name:        check_k8s_nodes
   Command:     $USER1$/check_k8s_nodes
   Description: Alerts on Kubernetes node health
   ```

4. Switch to **Arguments** tab and add (only those you intend to set):

   | Argument         | Value                              | Set if                              |
   |------------------|------------------------------------|-------------------------------------|
   | `--kubeconfig`   | `$check_k8s_kubeconfig$`           |                                     |
   | `--context`      | `$check_k8s_context$`              |                                     |
   | `--api-url`      | `$check_k8s_api_url$`              |                                     |
   | `--token`        | `$check_k8s_token$`                |                                     |
   | `--ca-cert`      | `$check_k8s_ca_cert$`              |                                     |
   | `--insecure`     |                                    | `$check_k8s_insecure$`              |
   | `-l`             | `$check_k8s_nodes_selector$`       |                                     |
   | `--ignore-cordon`|                                    | `$check_k8s_nodes_ignore_cordon$`   |
   | `-t`             | `$check_k8s_nodes_timeout$`        |                                     |
   | `-v`             |                                    | `$check_k8s_nodes_verbose$`         |

5. Click **Store** then **Deploy**

### Reuse Host Template

Reuse the `kubernetes-cluster` template defined under `check_k8s_pods` (it sets
`check_k8s_nodes = true` already). If that template does not exist yet, see
`check_k8s_pods/INSTALL.md`.

### Create Service

1. Navigate to **Icinga Director > Services > Apply Rules**
2. Click **+ Add**
3. Fill in:

   ```
   Name:          check_k8s_nodes
   Check command: check_k8s_nodes
   ```

4. Switch to **Assign** tab and add rule:
   - `host.vars.check_k8s_nodes` is `true`
   - or: `host.templates` contains `kubernetes-cluster`

5. Click **Store** then **Deploy**

## Verification

```bash
/usr/lib/nagios/plugins/check_k8s_nodes \
  --kubeconfig /etc/icinga2/k8s/prod.kubeconfig
```

Expected output:

```
check_k8s_nodes OK - All 6 node(s) Ready and healthy | nodes_total=6 nodes_ready=6 nodes_warning=0;;;0 nodes_critical=0;;;0
```

```bash
icinga2 object list --type Service --name "check_k8s_nodes"
journalctl -u icinga2 -f
```
