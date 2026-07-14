# check_k8s_pods

Alerts on Kubernetes pods that are not Running/Ready, that are stuck in failed
image-pull or CrashLoopBackOff states, that have been Pending beyond a grace
period, or whose container restart counts exceed configurable thresholds.

## Requirements

- Icinga 2 >= 2.13.0
- Python >= 3.8
- Python package: `kubernetes` (see `requirements.txt`)
- Network reachability from the Icinga node to the target API server
- A kubeconfig file *or* a Bearer token with permission to `list` pods in the
  target namespaces (cluster-wide read works fine; a `view` ClusterRoleBinding
  is enough)

## Compatibility

See Compatibility Matrix below.

## Usage

```
check_k8s_pods [--kubeconfig PATH [--context NAME]
              | --api-url URL --token TOKEN [--ca-cert PATH | --insecure]]
             [-n NAMESPACE ...] [--exclude-namespace NS ...]
             [-l SELECTOR] [-w INT] [-c INT]
             [--pending-grace SECONDS] [--exclude-restart-pod PATTERN ...]
             [-t SECONDS] [-v] [-V] [-h]
```

## Arguments

| Argument               | Required | Default | Description                                                              |
|------------------------|----------|---------|--------------------------------------------------------------------------|
| --kubeconfig           | One of   |         | Path to kubeconfig file                                                  |
| --context              | No       |         | kubeconfig context (defaults to current-context)                         |
| --api-url              | One of   |         | API server URL, e.g. `https://kube-api:6443`                             |
| --token                | with --api-url | | Bearer token                                                             |
| --ca-cert              | No       |         | CA cert path for API server                                              |
| --insecure             | No       | false   | Skip TLS verification (not recommended)                                  |
| -n / --namespace       | No       | all     | Namespace to check. Repeat for multiple.                                 |
| --exclude-namespace    | No       |         | Namespace to skip (ignored when -n given). Repeat for multiple.          |
| -l / --selector        | No       |         | Label selector, e.g. `app=nginx,tier!=cache`                             |
| -w / --restart-warning | No       | 5       | WARNING when any container restart count >= this                         |
| -c / --restart-critical| No       | 20      | CRITICAL when any container restart count >= this                        |
| --pending-grace        | No       | 300     | Seconds a pod may remain Pending before CRITICAL                         |
| --exclude-restart-pod  | No       |         | Skip restart-count thresholds for pods matching this namespace/name glob. Repeat for multiple. |
| -t / --timeout         | No       | 30      | Plugin timeout in seconds                                                |
| -v / --verbose         | No       | false   | Include OK pods in output                                                |
| -V / --version         | No       |         | Show plugin version                                                      |
| -h / --help            | No       |         | Show help                                                                |

## Argument Reference

The table above is a quick reference; this section explains *what each
argument is for, when you would set it, and what a typical value looks like*.

### Authentication

You must pick exactly one auth method: a kubeconfig file, or a raw
API URL + Bearer token. Pick **kubeconfig** if you already have one configured
(simplest); pick **token** if Icinga should talk to a cluster it has no client
config for, with a dedicated service-account credential.

#### `--kubeconfig PATH`

Path to a kubeconfig file. Same format as `~/.kube/config`. The Icinga user
must be able to read this file (see [INSTALL.md](INSTALL.md) for permissions).

```bash
check_k8s_pods --kubeconfig /etc/icinga2/k8s/prod.kubeconfig
```

Use this when:
- You already manage cluster access via kubeconfig elsewhere (e.g. a CI runner
  shares its kubeconfig with the Icinga host).
- You want to monitor multiple clusters from one Icinga host — one kubeconfig
  per cluster, one host object per cluster.

#### `--context NAME`

Selects a specific context within the kubeconfig instead of `current-context`.
Useful when a single kubeconfig holds entries for several clusters.

```bash
check_k8s_pods --kubeconfig ~/.kube/config --context prod-eu
```

#### `--api-url URL`

API server URL. Pair with `--token`. Get it from `kubectl cluster-info`.

```bash
check_k8s_pods \
  --api-url https://kube-api.prod.example.com:6443 \
  --token "$(cat /etc/icinga2/k8s/prod.token)" \
  --ca-cert /etc/icinga2/k8s/prod-ca.crt
```

Use this when:
- You provisioned a dedicated read-only ServiceAccount (recommended for Icinga).
- You don't want to manage a kubeconfig file just for monitoring.

#### `--token TOKEN`

Bearer token for the ServiceAccount. Required with `--api-url`. Pass the value
directly or read it from a file at invocation time (`$(cat ...)`).

In Icinga 2 config, store the token in a custom var on the host object — keep
that file outside version control (the repo's `.gitignore` already excludes
`secrets.conf`).

#### `--ca-cert PATH`

Path to the CA certificate that signed the API server's serving cert. Without
this, Python's default trust store is used — which usually does **not** trust
a self-signed Kubernetes CA. Extract from the ServiceAccount token Secret's
`data.ca.crt` field (see INSTALL.md Step 6).

```bash
check_k8s_pods --api-url https://... --token ... --ca-cert /etc/icinga2/k8s/prod-ca.crt
```

#### `--insecure`

Skips TLS certificate verification. **Not recommended.** A Man-in-the-Middle
between Icinga and the API server can intercept your Bearer token.

Only acceptable for:
- Local development clusters (`kind`, `minikube`).
- Throwaway test clusters where the network path is trusted.

### Scope: which pods to evaluate

By default the plugin evaluates **every** pod in **every** namespace. The
flags below narrow scope.

#### `-n NAMESPACE` / `--namespace NAMESPACE` (repeatable)

Restrict the check to one or more specific namespaces. **Repeat the flag**
once per namespace — comma-separated values do not work
(`-n a,b` is read as one namespace literally named `a,b`).

```bash
# Three namespaces — one -n each
check_k8s_pods --kubeconfig prod.kubeconfig -n production -n staging -n payments
```

In **Icinga 2 config**, the CheckCommand uses `repeat_key = true`, so set the
host var as an **array** — Icinga expands each element into its own `-n`
flag:

```icinga2
vars.check_k8s_pods_namespaces = [ "production", "staging", "payments" ]
```

In **Icinga Director**, set the matching custom field as an Array data type
(one element per namespace).

Use this when:
- You want one Icinga service per environment (e.g. one service for
  `production`, another for `staging`).
- Your monitoring SA only has namespace-scoped RBAC (RoleBinding, not
  ClusterRoleBinding).

> One API list call is made per included namespace. `-n` with many namespaces
> is slower than `--exclude-namespace` covering the same scope (which makes a
> single cluster-wide call and filters locally) — bump `-t` if you list many.

#### `--exclude-namespace NAMESPACE` (repeatable)

Skips namespaces when checking cluster-wide. **Repeat the flag** once per
namespace (no comma-separated values). **Silently ignored when `-n` is also
given** — the include list takes precedence and the plugin never combines the
two (there is no "all except X within Y" mode).

```bash
check_k8s_pods --kubeconfig prod.kubeconfig \
  --exclude-namespace kube-system \
  --exclude-namespace ingress-nginx \
  --exclude-namespace cert-manager
```

In **Icinga 2 config**, set the host var as an array:

```icinga2
vars.check_k8s_pods_exclude_namespaces = [
  "kube-system",
  "ingress-nginx",
  "cert-manager",
]
```

In **Icinga Director**, set the matching custom field as an Array data type.

Use this when:
- You want broad coverage but expect noise from `kube-system` (always
  evolving, frequent kubelet-driven restarts).
- A namespace is owned by a different team and you don't want to alert on it.

#### `-l SELECTOR` / `--selector SELECTOR`

Standard Kubernetes label selector. Comma-separated equality
(`app=nginx`) or inequality (`tier!=cache`) clauses; set operators
(`environment in (prod, staging)`) work too.

```bash
# Only pods labelled tier=frontend in any namespace
check_k8s_pods --kubeconfig prod.kubeconfig -l tier=frontend

# Exclude batch jobs that we know are noisy
check_k8s_pods --kubeconfig prod.kubeconfig -l 'workload-type!=batch'
```

Use this when:
- You want different thresholds or alert routing for different workload
  classes (e.g. stricter for `tier=frontend`, looser for `tier=batch`).

### Thresholds & alert tuning

#### `-w INT` / `--restart-warning INT` (default: `5`)

Container restart count at or above which the pod is reported WARNING.
`restart_count` is cumulative over the pod's lifetime, so a long-lived pod
will accumulate restarts gradually. Choose a value that catches "this pod is
flapping" but ignores "this pod has been around for months and restarted
twice during host reboots".

Example tuning:

| Workload type            | Suggested `-w` | Suggested `-c` |
|--------------------------|----------------|----------------|
| Latency-sensitive web    | 3              | 10             |
| Batch / data-pipeline    | 10             | 50             |
| Default (mixed cluster)  | 5              | 20             |

#### `-c INT` / `--restart-critical INT` (default: `20`)

Container restart count at or above which the pod is reported CRITICAL.
Must be `>= --restart-warning`. The plugin alerts CRITICAL on the **first
occurrence** of an excessive count — there is no "for X minutes" hysteresis,
so pick a value high enough to indicate genuine instability.

#### `--pending-grace SECONDS` (default: `300`)

A pod in the `Pending` phase is OK until it has been Pending for this many
seconds, after which it is CRITICAL. Catches pods stuck waiting for a node
(unschedulable), an image pull at the kubelet level, or volume attachment.

Example tuning:

```bash
# Cluster with autoscaling — give the autoscaler time to add a node
check_k8s_pods --kubeconfig prod.kubeconfig --pending-grace 600

# Tight latency requirements — alert quickly
check_k8s_pods --kubeconfig prod.kubeconfig --pending-grace 120
```

> Note: pods stuck in **`ImagePullBackOff`** are caught immediately as
> CRITICAL via the container-waiting-reason check — `--pending-grace` does
> not apply to them.

#### `--exclude-restart-pod PATTERN` (repeatable)

Suppresses **only** the restart-count thresholds (`-w` / `-c`) for pods
whose `namespace/name` matches the given shell glob. Every other health
check still applies to matched pods — this is **not** a full pod mute:

- **Still CRITICAL** for matched pods: CrashLoopBackOff, ImagePullBackOff,
  ErrImagePull, other bad waiting reasons, phase `Failed` / `Unknown`,
  container terminated with non-zero exit, Pending beyond `--pending-grace`.
- **Still WARNING** for matched pods: Running with containers not ready.
- **Not counted** in the `max_restarts` performance data metric.

Pattern syntax is `fnmatch` (Python shell glob) matched against
`namespace/name` — `*` (any run of chars), `?` (single char), `[abc]`
(char class). Match is case-sensitive; K8s resource names are lowercase.

```bash
# Ignore restart-count for one specific pod
check_k8s_pods --kubeconfig prod.kubeconfig \
  --exclude-restart-pod 'default/flaky-worker-abcd1234'

# Ignore all pods of a Deployment (matching its pod-name prefix)
check_k8s_pods --kubeconfig prod.kubeconfig \
  --exclude-restart-pod 'batch/oom-known-*'

# Multiple exclusions — repeat the flag
check_k8s_pods --kubeconfig prod.kubeconfig \
  --exclude-restart-pod 'ci/*' \
  --exclude-restart-pod 'chaos/*'
```

**Repeat the flag** once per pattern — comma-separated values do not work
(`--exclude-restart-pod 'a,b'` is read as a single pattern that will not
match anything).

In **Icinga 2 config**, the CheckCommand uses `repeat_key = true`, so set
the host var as an **array**:

```icinga2
vars.check_k8s_pods_exclude_restart_pods = [
  "ci/flaky-*",
  "batch/oom-known-*",
]
```

In **Icinga Director**, set the matching custom field as an Array data
type (one element per pattern).

Use this when:
- A pod is known to restart routinely by design (chaos-monkey targets,
  batch jobs that OOM under investigation) and generates ticket noise.
- A CrashLoopBackOff is being tracked elsewhere (dedicated ticket, war-room)
  and you want Icinga to stop paging on the restart count while other
  health signals for that pod still fire.

Do NOT use this to hide a broken pod entirely — CrashLoopBackOff is not
suppressed by this flag. If you truly want to skip a pod's every check,
use `--exclude-namespace` at the namespace level instead.

### Execution & output

#### `-t SECONDS` / `--timeout SECONDS` (default: `30`)

Hard plugin timeout. Counts wall time for the entire check, including the
API call and result evaluation. On timeout the plugin exits UNKNOWN.

Raise it if your API server is slow under load (large clusters, geographically
remote API endpoint). Lower it for tight check intervals where a slow plugin
delays the next scheduled run.

```bash
check_k8s_pods --kubeconfig prod.kubeconfig -t 15   # tight latency
check_k8s_pods --kubeconfig prod.kubeconfig -t 60   # large/remote cluster
```

#### `-v` / `--verbose`

Includes a `[OK]` line for every healthy pod in addition to the bad-pod
detail. Useful for one-off investigations from the command line; **leave off**
in Icinga service definitions or your event history will be massive on every
state change.

```bash
check_k8s_pods --kubeconfig prod.kubeconfig -v | less
```

#### `-V` / `--version`

Prints the plugin version and exits with status `OK`.

#### `-h` / `--help`

Standard argparse help, lists all arguments and exits.

## Putting it together: example invocations

Healthy production cluster, kubeconfig auth, skip cluster system namespaces:

```bash
check_k8s_pods \
  --kubeconfig /etc/icinga2/k8s/prod.kubeconfig \
  --exclude-namespace kube-system \
  --exclude-namespace ingress-nginx \
  -t 30
```

Multi-tenant cluster, dedicated service per business unit, token auth:

```bash
check_k8s_pods \
  --api-url https://kube-api.prod.example.com:6443 \
  --token "$(cat /etc/icinga2/k8s/prod.token)" \
  --ca-cert /etc/icinga2/k8s/prod-ca.crt \
  -n team-payments -n team-payments-internal \
  -w 3 -c 10 \
  --pending-grace 180
```

Local dev cluster, lenient thresholds:

```bash
check_k8s_pods \
  --kubeconfig ~/.kube/config --context kind-dev \
  -w 50 -c 200 \
  --pending-grace 60 \
  -v
```

## Alert Logic

| Pod condition                                          | State    |
|--------------------------------------------------------|----------|
| Container waiting: CrashLoopBackOff / ImagePullBackOff / ErrImagePull / InvalidImageName / CreateContainerConfigError / CreateContainerError / RunContainerError / ContainerCannotRun | CRITICAL |
| Pod phase Failed or Unknown                            | CRITICAL |
| Container terminated with non-zero exit code (non-Succeeded pod) | CRITICAL |
| Pod Pending longer than `--pending-grace`              | CRITICAL |
| Container restart count >= `--restart-critical` (unless pod matches `--exclude-restart-pod`) | CRITICAL |
| Running pod with one or more containers not Ready      | WARNING  |
| Container restart count >= `--restart-warning` (unless pod matches `--exclude-restart-pod`) | WARNING  |
| Pod Succeeded (e.g. Job)                               | OK       |
| Otherwise                                              | OK       |

## Example Output

```
check_k8s_pods OK - All 42 pod(s) healthy | pods_total=42 pods_ok=42 pods_warning=0;;;0 pods_critical=0;;;0 max_restarts=2;5;20;0

check_k8s_pods CRITICAL - 40/42 pod(s) OK, 1 CRITICAL, 1 WARNING | pods_total=42 pods_ok=40 pods_warning=1;;;0 pods_critical=1;;;0 max_restarts=23;5;20;0
[CRITICAL] default/web-7f9c-q2x4z container=web waiting=CrashLoopBackOff
[WARNING] default/web-7f9c-m8k1l Running but containers not ready: sidecar
```

## Performance Data

| Label           | UOM | Description                                  |
|-----------------|-----|----------------------------------------------|
| `pods_total`    |     | Total pods evaluated                         |
| `pods_ok`       |     | Pods in OK state                             |
| `pods_warning`  |     | Pods in WARNING state                        |
| `pods_critical` |     | Pods in CRITICAL state                       |
| `max_restarts`  |     | Highest container restart count among pods (excludes pods matched by `--exclude-restart-pod`) |

## Known Limitations

- Only `list` permission is required; the plugin does not exec into pods.
- Init container restart counts contribute to `max_restarts`, but init container
  not-ready state is not flagged separately (init failures surface via the
  waiting-reason check).
- `Succeeded` pods are always OK — Job/CronJob status should be monitored with a
  dedicated check.

## Compatibility Matrix

| Plugin Version | Icinga 2 Version | OS                     | Lang Version |
|----------------|------------------|------------------------|--------------|
| 1.1.0          | >= 2.13.0        | Ubuntu 22.04/24.04     | Python 3.10  |
| 1.1.0          | >= 2.13.0        | Debian 11/12           | Python 3.9/3.11 |
| 1.1.0          | >= 2.13.0        | RHEL / Rocky Linux 8/9 | Python 3.8/3.9 |

## License

MIT - see [LICENSE](../../../LICENSE)
