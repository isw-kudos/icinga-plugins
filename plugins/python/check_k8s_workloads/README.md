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
