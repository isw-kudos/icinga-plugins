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

## Argument Reference

The table above is a quick reference; this section explains *what each
argument is for, when you would set it, and what a typical value looks like*.

### Authentication

Identical to [check_k8s_pods authentication](../check_k8s_pods/README.md#authentication):
pick one of `--kubeconfig [--context]` or `--api-url --token [--ca-cert | --insecure]`.

> **Important:** `nodes` is a cluster-scoped resource, so a namespace-scoped
> `RoleBinding` is **not** sufficient — the ServiceAccount must be bound to a
> `ClusterRole` that grants `list` on `nodes`. The default `view` ClusterRole
> does NOT include `nodes`; see [INSTALL.md](INSTALL.md#kubernetes-rbac).

#### `--kubeconfig PATH` — Path to a kubeconfig file

```bash
check_k8s_nodes --kubeconfig /etc/icinga2/k8s/prod.kubeconfig
```

#### `--context NAME` — Selects a non-default context within the kubeconfig

```bash
check_k8s_nodes --kubeconfig ~/.kube/config --context prod-eu
```

#### `--api-url URL` + `--token TOKEN` — Direct API auth

```bash
check_k8s_nodes \
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

### Scope: which nodes to evaluate

#### `-l SELECTOR` / `--selector SELECTOR`

Standard Kubernetes label selector applied to **nodes**. Common keys:

| Selector                                  | What it matches                              |
|-------------------------------------------|----------------------------------------------|
| `node-role.kubernetes.io/control-plane=`  | Control-plane nodes only                     |
| `node-role.kubernetes.io/worker=`         | Worker nodes only (if your distro sets it)   |
| `kubernetes.io/os=linux`                  | Linux nodes                                  |
| `topology.kubernetes.io/zone=eu-west-1a`  | Nodes in a specific availability zone        |
| Your own label, e.g. `gpu=nvidia-a100`    | Hardware-specific pools                      |

```bash
# One Icinga service for control-plane health, another for workers
check_k8s_nodes --kubeconfig prod.kubeconfig -l node-role.kubernetes.io/control-plane=
check_k8s_nodes --kubeconfig prod.kubeconfig -l '!node-role.kubernetes.io/control-plane'
```

Use this to:
- Apply different escalation policies to control-plane vs worker nodes.
- Per-zone health checks for availability-zone aware monitoring.
- Isolate GPU / specialized hardware pools whose failure modes differ.

### Behaviour tuning

#### `--ignore-cordon`

Suppresses the WARNING that fires when a node has `spec.unschedulable=true`.

Cordoned nodes are usually intentional (maintenance, draining before a kernel
update, isolating a flaky node for investigation). Whether to alert depends
on your operating model:

| Scenario                                      | Recommended                  |
|-----------------------------------------------|------------------------------|
| Long-running production cluster, cordon == incident | Leave default (alert)  |
| Frequent rolling kernel updates / autoscaling | `--ignore-cordon` (silence) |
| Mixed: alert during business hours only       | Two separate services with different schedules |

```bash
# Maintenance-aware check that ignores cordon
check_k8s_nodes --kubeconfig prod.kubeconfig --ignore-cordon
```

Note that **Ready** and pressure conditions still alert even with
`--ignore-cordon` — only the cordoned-state WARNING is suppressed.

### Execution & output

#### `-t SECONDS` / `--timeout SECONDS` (default: `30`)

Hard plugin timeout. Node listing is a single API call against a cluster-scoped
resource — usually fast even on large clusters. Increase if your API server is
slow or remote:

```bash
check_k8s_nodes --kubeconfig prod.kubeconfig -t 60
```

#### `-v` / `--verbose`

Adds an `[OK]` line per healthy node. Useful for interactive runs; leave off
in service definitions or large clusters will generate enormous Icinga event
history entries.

```bash
check_k8s_nodes --kubeconfig prod.kubeconfig -v
```

#### `-V` / `--version`, `-h` / `--help`

Standard.

## Putting it together: example invocations

Whole-cluster node health, default thresholds:

```bash
check_k8s_nodes --kubeconfig /etc/icinga2/k8s/prod.kubeconfig
```

Control-plane-only check, alert on any cordon:

```bash
check_k8s_nodes \
  --kubeconfig /etc/icinga2/k8s/prod.kubeconfig \
  -l node-role.kubernetes.io/control-plane=
```

Worker-pool check during cluster autoscaling (cordons are normal):

```bash
check_k8s_nodes \
  --kubeconfig /etc/icinga2/k8s/prod.kubeconfig \
  -l '!node-role.kubernetes.io/control-plane' \
  --ignore-cordon
```

Per-zone availability check (token auth):

```bash
check_k8s_nodes \
  --api-url https://kube-api.prod.example.com:6443 \
  --token "$(cat /etc/icinga2/k8s/prod.token)" \
  --ca-cert /etc/icinga2/k8s/prod-ca.crt \
  -l topology.kubernetes.io/zone=eu-west-1a
```

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
