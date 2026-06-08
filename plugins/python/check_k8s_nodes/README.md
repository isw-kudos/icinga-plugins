# check_k8s_nodes

Alerts on Kubernetes nodes that are NotReady, under memory/disk/PID/network
pressure, or cordoned (`spec.unschedulable=true`).

## Requirements

- Icinga 2 >= 2.13.0
- Python >= 3.8
- Python package: `kubernetes` (see `requirements.txt`)
- A kubeconfig file *or* a Bearer token with permission to `list` nodes
  (cluster-scoped). The built-in `view` ClusterRole is sufficient.

## Compatibility

See Compatibility Matrix below.

## Usage

```
check_k8s_nodes [--kubeconfig PATH [--context NAME]
              | --api-url URL --token TOKEN [--ca-cert PATH | --insecure]]
             [-l SELECTOR] [--ignore-cordon]
             [-t SECONDS] [-v] [-V] [-h]
```

## Arguments

| Argument         | Required | Default | Description                                                |
|------------------|----------|---------|------------------------------------------------------------|
| --kubeconfig     | One of   |         | Path to kubeconfig file                                    |
| --context        | No       |         | kubeconfig context (defaults to current-context)           |
| --api-url        | One of   |         | API server URL                                             |
| --token          | with --api-url | | Bearer token                                               |
| --ca-cert        | No       |         | CA cert path for API server                                |
| --insecure       | No       | false   | Skip TLS verification (not recommended)                    |
| -l / --selector  | No       |         | Node label selector, e.g. `role=worker`                    |
| --ignore-cordon  | No       | false   | Do not WARN on cordoned nodes (useful during maintenance)  |
| -t / --timeout   | No       | 30      | Plugin timeout in seconds                                  |
| -v / --verbose   | No       | false   | Include OK nodes in output                                 |
| -V / --version   | No       |         | Show plugin version                                        |
| -h / --help      | No       |         | Show help                                                  |

## Alert Logic

| Condition                                                           | State    |
|---------------------------------------------------------------------|----------|
| Node has no `Ready` condition                                       | CRITICAL |
| `Ready != True` (NotReady / Unknown)                                | CRITICAL |
| `MemoryPressure == True`                                            | CRITICAL |
| `DiskPressure == True`                                              | CRITICAL |
| `PIDPressure == True`                                               | CRITICAL |
| `NetworkUnavailable == True`                                        | CRITICAL |
| `spec.unschedulable == true` (cordoned) and not `--ignore-cordon`   | WARNING  |
| Otherwise                                                           | OK       |

If `list_node` returns zero nodes the plugin returns **UNKNOWN** — a cluster
should always have at least one node, and zero usually indicates an RBAC or
selector misconfiguration rather than a healthy state.

## Example Output

```
check_k8s_nodes OK - All 6 node(s) Ready and healthy | nodes_total=6 nodes_ready=6 nodes_warning=0;;;0 nodes_critical=0;;;0

check_k8s_nodes CRITICAL - 4/6 node(s) Ready, 1 CRITICAL, 1 WARNING | nodes_total=6 nodes_ready=4 nodes_warning=1;;;0 nodes_critical=1;;;0
[CRITICAL] worker-03 NotReady (reason=KubeletNotReady)
[WARNING] worker-05 cordoned (spec.unschedulable=true)
```

## Performance Data

| Label             | UOM | Description                  |
|-------------------|-----|------------------------------|
| `nodes_total`     |     | Total nodes evaluated        |
| `nodes_ready`     |     | Nodes in OK state            |
| `nodes_warning`   |     | Nodes in WARNING state       |
| `nodes_critical`  |     | Nodes in CRITICAL state      |

## Known Limitations

- Resource usage thresholds (CPU/memory/disk %) are not evaluated — only the
  binary pressure conditions reported by the kubelet. Use metrics-server-based
  checks (`check_kubernetes_resources` style) for utilization alerts.
- Taints other than the standard `node.kubernetes.io/unschedulable` are not
  inspected.

## Compatibility Matrix

| Plugin Version | Icinga 2 Version | OS                     | Lang Version |
|----------------|------------------|------------------------|--------------|
| 1.0.0          | >= 2.13.0        | Ubuntu 22.04/24.04     | Python 3.10  |
| 1.0.0          | >= 2.13.0        | Debian 11/12           | Python 3.9/3.11 |
| 1.0.0          | >= 2.13.0        | RHEL / Rocky Linux 8/9 | Python 3.8/3.9 |

## License

MIT - see [LICENSE](../../../LICENSE)
