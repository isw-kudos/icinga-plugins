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
             [--pending-grace SECONDS] [-t SECONDS] [-v] [-V] [-h]
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
| -t / --timeout         | No       | 30      | Plugin timeout in seconds                                                |
| -v / --verbose         | No       | false   | Include OK pods in output                                                |
| -V / --version         | No       |         | Show plugin version                                                      |
| -h / --help            | No       |         | Show help                                                                |

## Alert Logic

| Pod condition                                          | State    |
|--------------------------------------------------------|----------|
| Container waiting: CrashLoopBackOff / ImagePullBackOff / ErrImagePull / InvalidImageName / CreateContainerConfigError / CreateContainerError / RunContainerError / ContainerCannotRun | CRITICAL |
| Pod phase Failed or Unknown                            | CRITICAL |
| Container terminated with non-zero exit code (non-Succeeded pod) | CRITICAL |
| Pod Pending longer than `--pending-grace`              | CRITICAL |
| Container restart count >= `--restart-critical`        | CRITICAL |
| Running pod with one or more containers not Ready      | WARNING  |
| Container restart count >= `--restart-warning`         | WARNING  |
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
| `max_restarts`  |     | Highest container restart count among pods   |

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
| 1.0.0          | >= 2.13.0        | Ubuntu 22.04/24.04     | Python 3.10  |
| 1.0.0          | >= 2.13.0        | Debian 11/12           | Python 3.9/3.11 |
| 1.0.0          | >= 2.13.0        | RHEL / Rocky Linux 8/9 | Python 3.8/3.9 |

## License

MIT - see [LICENSE](../../../LICENSE)
