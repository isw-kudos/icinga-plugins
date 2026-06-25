# Installation Guide: check_k8s_workloads

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
cp check_k8s_workloads.py /usr/lib64/nagios/plugins/check_k8s_workloads
chmod +x /usr/lib64/nagios/plugins/check_k8s_workloads
```

> **Plugin path:** these examples use the AlmaLinux 9 path `/usr/lib64/nagios/plugins`
> (the 64-bit RHEL-family `PluginDir`). On Debian/Ubuntu it is `/usr/lib/nagios/plugins`
> — confirm your distribution's `PluginDir` constant and adjust the paths accordingly.

Install the Python client (see `check_k8s_pods/INSTALL.md` for distro
specifics — the same package satisfies all three k8s checks).

## Kubernetes RBAC

The plugin needs `list` on `deployments.apps` and `statefulsets.apps`. Both
are covered by the built-in `view` ClusterRole, and also by the custom
`icinga-readonly` ClusterRole defined in
[`check_k8s_pods/INSTALL.md`](../check_k8s_pods/INSTALL.md#kubernetes-rbac).

Reuse the same ServiceAccount and token created for `check_k8s_pods` — no
extra RBAC objects are needed for this plugin.

If you only want to deploy `check_k8s_workloads` standalone, the minimum is:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: icinga-workloads-readonly
rules:
  - apiGroups: ["apps"]
    resources: ["deployments", "statefulsets"]
    verbs: ["list"]
```

…plus a ServiceAccount, ClusterRoleBinding, and long-lived token Secret as
described in Steps 1, 3, and 4 of `check_k8s_pods/INSTALL.md`.

## Method 1: Config File Deployment

### CheckCommand Definition

```bash
cp icinga2/checkcommand.conf /etc/icinga2/conf.d/check_k8s_workloads_command.conf
```

See [icinga2/checkcommand.conf](icinga2/checkcommand.conf) for full contents.

### Service Definition

```bash
cp icinga2/service.conf /etc/icinga2/conf.d/check_k8s_workloads_service.conf
```

See [icinga2/service.conf](icinga2/service.conf) for full contents.

The shared `kubernetes-cluster` host template (installed alongside
`check_k8s_pods`) already enables this service via
`vars.check_k8s_workloads = true`.

Per-host overrides:

```icinga2
object Host "prod-cluster" {
  import "kubernetes-cluster"

  vars.check_k8s_workloads_exclude_namespaces = [ "kube-system", "ingress-nginx" ]
  vars.check_k8s_workloads_skip_statefulsets  = false
  vars.check_k8s_workloads_skip_deployments   = false
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
   Name:        check_k8s_workloads
   Command:     $USER1$/check_k8s_workloads
   Description: Alerts on Kubernetes Deployment and StatefulSet health
   ```

4. Switch to **Arguments** tab and add (only the ones you intend to set):

   | Argument               | Value                                              | Repeat key | Set if                                       |
   |------------------------|----------------------------------------------------|------------|----------------------------------------------|
   | `--kubeconfig`         | `$check_k8s_kubeconfig$`                           | No         |                                              |
   | `--context`            | `$check_k8s_context$`                              | No         |                                              |
   | `--api-url`            | `$check_k8s_api_url$`                              | No         |                                              |
   | `--token`              | `$check_k8s_token$`                                | No         |                                              |
   | `--ca-cert`            | `$check_k8s_ca_cert$`                              | No         |                                              |
   | `--insecure`           |                                                    | No         | `$check_k8s_insecure$`                       |
   | `-n`                   | `$check_k8s_workloads_namespaces$`                 | Yes        |                                              |
   | `--exclude-namespace`  | `$check_k8s_workloads_exclude_namespaces$`         | Yes        |                                              |
   | `-l`                   | `$check_k8s_workloads_selector$`                   | No         |                                              |
   | `--no-deployments`     |                                                    | No         | `$check_k8s_workloads_skip_deployments$`     |
   | `--no-statefulsets`    |                                                    | No         | `$check_k8s_workloads_skip_statefulsets$`    |
   | `-t`                   | `$check_k8s_workloads_timeout$`                    | No         |                                              |
   | `-v`                   |                                                    | No         | `$check_k8s_workloads_verbose$`              |

5. Click **Store** then **Deploy**

### Reuse Host Template

Reuse the `kubernetes-cluster` template defined under `check_k8s_pods` (it sets
`check_k8s_workloads = true` already). If that template does not exist yet, see
`check_k8s_pods/INSTALL.md`.

### Create Service

1. Navigate to **Icinga Director > Services > Apply Rules**
2. Click **+ Add**
3. Fill in:

   ```
   Name:          check_k8s_workloads
   Check command: check_k8s_workloads
   ```

4. Switch to **Assign** tab and add rule:
   - `host.vars.check_k8s_workloads` is `true`
   - or: `host.templates` contains `kubernetes-cluster`

5. Click **Store** then **Deploy**

## Verification

```bash
/usr/lib64/nagios/plugins/check_k8s_workloads \
  --kubeconfig /etc/icinga2/k8s/prod.kubeconfig \
  --exclude-namespace kube-system
```

Expected output:

```
check_k8s_workloads OK - All 18 workload(s) healthy (54/54 replicas ready) | workloads_total=18 workloads_ok=18 workloads_warning=0;;;0 workloads_critical=0;;;0 replicas_desired=54 replicas_ready=54
```

```bash
icinga2 object list --type Service --name "check_k8s_workloads"
journalctl -u icinga2 -f
```
