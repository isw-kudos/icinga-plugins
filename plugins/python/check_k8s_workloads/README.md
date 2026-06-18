# check_k8s_workloads

Alerts on Kubernetes **Deployments** and **StatefulSets** that have fewer ready
replicas than desired, are fully down, or whose rollout has stalled.

## Requirements

- Icinga 2 >= 2.13.0
- Python >= 3.8
- Python package: `kubernetes` (see `requirements.txt`)
- A kubeconfig file *or* a Bearer token with permission to `list` deployments
  and statefulsets in the target namespaces (the built-in `view` ClusterRole is
  sufficient)

## Compatibility

See Compatibility Matrix below.

## Usage

```
check_k8s_workloads [--kubeconfig PATH [--context NAME]
                   | --api-url URL --token TOKEN [--ca-cert PATH | --insecure]]
                  [-n NAMESPACE ...] [--exclude-namespace NS ...]
                  [-l SELECTOR]
                  [--no-deployments] [--no-statefulsets]
                  [-t SECONDS] [-v] [-V] [-h]
```

## Arguments

| Argument                  | Required | Default | Description                                                   |
|---------------------------|----------|---------|---------------------------------------------------------------|
| --kubeconfig              | One of   |         | Path to kubeconfig file                                       |
| --context                 | No       |         | kubeconfig context (defaults to current-context)              |
| --api-url                 | One of   |         | API server URL                                                |
| --token                   | with --api-url | | Bearer token                                                  |
| --ca-cert                 | No       |         | CA cert path for API server                                   |
| --insecure                | No       | false   | Skip TLS verification (not recommended)                       |
| -n / --namespace          | No       | all     | Namespace to check. Repeat for multiple.                      |
| --exclude-namespace       | No       |         | Namespace to skip (ignored when -n given).                    |
| -l / --selector           | No       |         | Label selector                                                |
| --no-deployments          | No       | false   | Skip Deployment checks                                        |
| --no-statefulsets         | No       | false   | Skip StatefulSet checks                                       |
| -t / --timeout            | No       | 30      | Plugin timeout in seconds                                     |
| -v / --verbose            | No       | false   | Include OK workloads in output                                |
| -V / --version            | No       |         | Show plugin version                                           |
| -h / --help               | No       |         | Show help                                                     |

## Argument Reference

The table above is a quick reference; this section explains *what each
argument is for, when you would set it, and what a typical value looks like*.

### Authentication

Identical to [check_k8s_pods authentication](../check_k8s_pods/README.md#authentication):
pick one of `--kubeconfig [--context]` or `--api-url --token [--ca-cert | --insecure]`.
The same ServiceAccount / token / kubeconfig configured for `check_k8s_pods`
works here without modification — `apps/v1` Deployments and StatefulSets are
covered by the same `view` permissions or by the custom `icinga-readonly`
ClusterRole described in [INSTALL.md](INSTALL.md#kubernetes-rbac).

#### `--kubeconfig PATH` — Path to a kubeconfig file

```bash
check_k8s_workloads --kubeconfig /etc/icinga2/k8s/prod.kubeconfig
```

#### `--context NAME` — Selects a non-default context within the kubeconfig

```bash
check_k8s_workloads --kubeconfig ~/.kube/config --context prod-eu
```

#### `--api-url URL` + `--token TOKEN` — Direct API auth

```bash
check_k8s_workloads \
  --api-url https://kube-api.prod.example.com:6443 \
  --token "$(cat /etc/icinga2/k8s/prod.token)" \
  --ca-cert /etc/icinga2/k8s/prod-ca.crt
```

#### `--ca-cert PATH` — CA that signed the API server's serving cert

Extract from the SA token Secret's `data.ca.crt`. Without `--ca-cert`, Python's
default trust store is used (usually does NOT trust a self-signed Kubernetes CA).

#### `--insecure` — Skip TLS verification

**Not recommended.** Acceptable only for `kind` / `minikube` / trusted-network
test clusters.

### Scope: which workloads to evaluate

By default the plugin lists **all Deployments and StatefulSets** in **every
namespace**. The flags below narrow that.

#### `-n NAMESPACE` / `--namespace NAMESPACE` (repeatable)

Restrict to specific namespaces. **Repeat the flag** once per namespace —
comma-separated values do not work (`-n a,b` is read as one namespace
literally named `a,b`).

```bash
# Single namespace
check_k8s_workloads --kubeconfig prod.kubeconfig -n production

# Multiple namespaces — one -n each
check_k8s_workloads --kubeconfig prod.kubeconfig -n production -n staging -n payments
```

In **Icinga 2 config**, the CheckCommand uses `repeat_key = true`, so set the
host var as an **array** — Icinga expands each element into its own `-n` flag:

```icinga2
vars.check_k8s_workloads_namespaces = [ "production", "staging", "payments" ]
```

In **Icinga Director**, set the matching custom field as an Array data type
(one element per namespace).

> One API list call per included namespace **per workload kind** (deployments
> and statefulsets). With both kinds enabled, `-n a -n b -n c` is six API
> calls total. For broad cluster coverage, `--exclude-namespace` is faster.

#### `--exclude-namespace NAMESPACE` (repeatable)

Skip namespaces when checking cluster-wide. **Repeat the flag** once per
namespace (no comma-separated values). **Silently ignored when `-n` is also
given** — the include list takes precedence and the plugin never combines
the two (there is no "all except X within Y" mode).

```bash
check_k8s_workloads --kubeconfig prod.kubeconfig \
  --exclude-namespace kube-system \
  --exclude-namespace cert-manager \
  --exclude-namespace ingress-nginx
```

In **Icinga 2 config**, set the host var as an array:

```icinga2
vars.check_k8s_workloads_exclude_namespaces = [
  "kube-system",
  "cert-manager",
  "ingress-nginx",
]
```

In **Icinga Director**, set the matching custom field as an Array data type.

Useful for excluding namespaces where deployments are intentionally scaled
to zero or actively changing replica counts (e.g. cert-manager during
certificate renewals — though that's usually short-lived).

#### `-l SELECTOR` / `--selector SELECTOR`

Standard Kubernetes label selector matched against workload labels (not the
pod template's labels — those are different).

```bash
# Only workloads owned by the platform team
check_k8s_workloads --kubeconfig prod.kubeconfig -l owner=platform

# Critical workloads only
check_k8s_workloads --kubeconfig prod.kubeconfig -l 'criticality in (high,critical)'
```

Use this to run different checks at different intervals or with different
notification rules per workload class.

### Workload type filtering

#### `--no-deployments`

Skip Deployment checks. Use when you want a separate Icinga service that
only covers StatefulSets (often desirable because StatefulSets are usually
stateful, slower to recover, and warrant a different escalation policy).

```bash
# Service A: deployments only (fast escalation)
check_k8s_workloads --kubeconfig prod.kubeconfig --no-statefulsets

# Service B: statefulsets only (different on-call rotation)
check_k8s_workloads --kubeconfig prod.kubeconfig --no-deployments
```

#### `--no-statefulsets`

Skip StatefulSet checks. Mirror of `--no-deployments`. Setting both flags
together is an error (the plugin returns UNKNOWN).

### Execution & output

#### `-t SECONDS` / `--timeout SECONDS` (default: `30`)

Hard plugin timeout. Two API list calls happen sequentially (deployments,
statefulsets), so on large clusters total time can be higher than a
single-resource check. Raise if you see UNKNOWN timeouts:

```bash
check_k8s_workloads --kubeconfig huge.kubeconfig -t 60
```

#### `-v` / `--verbose`

Adds an `[OK]` line per healthy workload to the output. Convenient
interactively (`check_k8s_workloads ... -v | less`); leave off in service
definitions.

#### `-V` / `--version`, `-h` / `--help`

Standard.

## Putting it together: example invocations

Cluster-wide check, skip noisy / system namespaces:

```bash
check_k8s_workloads \
  --kubeconfig /etc/icinga2/k8s/prod.kubeconfig \
  --exclude-namespace kube-system \
  --exclude-namespace cert-manager \
  --exclude-namespace ingress-nginx
```

StatefulSet-only check with a tighter timeout (data plane):

```bash
check_k8s_workloads \
  --kubeconfig /etc/icinga2/k8s/prod.kubeconfig \
  --no-deployments \
  -n data \
  -t 20
```

Per-team check via label selector with token auth:

```bash
check_k8s_workloads \
  --api-url https://kube-api.prod.example.com:6443 \
  --token "$(cat /etc/icinga2/k8s/prod.token)" \
  --ca-cert /etc/icinga2/k8s/prod-ca.crt \
  -l team=payments
```

## Alert Logic

For each Deployment / StatefulSet with `spec.replicas > 0`:

| Condition                                                                     | State    |
|-------------------------------------------------------------------------------|----------|
| `status.readyReplicas == 0` while desired > 0                                  | CRITICAL |
| Deployment Progressing=False with reason=ProgressDeadlineExceeded              | CRITICAL |
| `status.readyReplicas < spec.replicas`                                         | WARNING  |
| Generation has advanced but `status.observedGeneration` has not caught up      | WARNING  |
| Deployment `status.availableReplicas < spec.replicas` (minReadySeconds unmet)  | WARNING  |
| Otherwise                                                                      | OK       |

Workloads scaled to `replicas: 0` are intentional and report OK.

## Example Output

```
check_k8s_workloads OK - All 18 workload(s) healthy (54/54 replicas ready) | workloads_total=18 workloads_ok=18 workloads_warning=0;;;0 workloads_critical=0;;;0 replicas_desired=54 replicas_ready=54

check_k8s_workloads CRITICAL - 16/18 workload(s) OK (50/54 replicas ready), 1 CRITICAL, 1 WARNING | workloads_total=18 workloads_ok=16 workloads_warning=1;;;0 workloads_critical=1;;;0 replicas_desired=54 replicas_ready=50
[CRITICAL] Deployment default/api 0/3 ready
[WARNING] StatefulSet data/postgres 2/3 ready
```

## Performance Data

| Label                  | UOM | Description                                  |
|------------------------|-----|----------------------------------------------|
| `workloads_total`      |     | Total workloads evaluated                    |
| `workloads_ok`         |     | Workloads in OK state                        |
| `workloads_warning`    |     | Workloads in WARNING state                   |
| `workloads_critical`   |     | Workloads in CRITICAL state                  |
| `replicas_desired`     |     | Sum of `spec.replicas` across all workloads  |
| `replicas_ready`       |     | Sum of `status.readyReplicas` across all     |

## Known Limitations

- DaemonSets are not covered (use a dedicated check or extend this plugin).
- HorizontalPodAutoscaler / Custom Resources are not evaluated.
- "Stalled rollout" detection for StatefulSets relies on the generation/observed
  mismatch only; StatefulSets do not expose a Progressing condition.

## Compatibility Matrix

| Plugin Version | Icinga 2 Version | OS                     | Lang Version |
|----------------|------------------|------------------------|--------------|
| 1.0.0          | >= 2.13.0        | Ubuntu 22.04/24.04     | Python 3.10  |
| 1.0.0          | >= 2.13.0        | Debian 11/12           | Python 3.9/3.11 |
| 1.0.0          | >= 2.13.0        | RHEL / Rocky Linux 8/9 | Python 3.8/3.9 |

## License

MIT - see [LICENSE](../../../LICENSE)
