# icinga-plugins

A collection of Icinga 2 monitoring plugins developed by ISW Kudos.

## Available Plugins

| Plugin | Language | Description | Version | Status |
|--------|----------|-------------|---------|--------|
| [check_domino_mail](plugins/bash/check_domino_mail) | Bash | Checks HCL Domino 14 mail server health (7 sub-checks) | 1.0.0 | Stable |
| [check_nfs_mount](plugins/python/check_nfs_mount) | Python | Checks NFS mounts are mounted and accessible | 1.0.0 | Stable |
| [check_itop_unassigned_tickets](plugins/bash/check_itop_unassigned_tickets) | Bash | Checks iTop for unassigned tickets via REST API | 1.0.0 | Stable |
| [check_cnx_search](plugins/bash/check_cnx_search) | Bash | Checks HCL Connections search index freshness | 1.0.0 | Stable |
| [check_cnx_docs](plugins/bash/check_cnx_docs) | Bash | Checks HCL Connections Docs Conversion server (sym_monitor + soffice) | 1.0.0 | Stable |
| [check_k8s_pods](plugins/python/check_k8s_pods) | Python | Alerts on Kubernetes pod health (CrashLoopBackOff, ImagePullBackOff, Pending, restart counts) | 1.0.0 | Stable |
| [check_k8s_workloads](plugins/python/check_k8s_workloads) | Python | Alerts on Kubernetes Deployment/StatefulSet replica health and stalled rollouts | 1.0.0 | Stable |
| [check_k8s_nodes](plugins/python/check_k8s_nodes) | Python | Alerts on Kubernetes node Ready / pressure conditions and cordoned nodes | 1.0.0 | Stable |
| [check_isds_monitor](plugins/bash/check_isds_monitor) | Bash | Checks IBM Security Directory Server cn=monitor (worker pool, connections, throughput, cache hit ratios) | 1.1.2 | Stable |
| [check_isds_replication](plugins/bash/check_isds_replication) | Bash | Checks IBM Security Directory Server replication agreement state and pending-change backlog | 1.1.2 | Stable |
| [check_isds_backend](plugins/bash/check_isds_backend) | Bash | Checks IBM Security Directory Server process liveness and DB2 backend (tablespace/log usage) | 1.0.2 | Stable |
| [check_isds_cert](plugins/bash/check_isds_cert) | Bash | Checks IBM Security Directory Server GSKit keystore (.kdb) TLS certificate expiry | 1.0.0 | Stable |

## Compatibility

| Plugin | Icinga 2 | OS | Lang Version |
|--------|----------|----|--------------|
| check_domino_mail | >= 2.13.0 | RHEL / Rocky Linux 8/9 | Bash 4.x |
| check_domino_mail | >= 2.13.0 | Ubuntu 22.04/24.04 | Bash 5.x |
| check_nfs_mount | >= 2.13.0 | Ubuntu 22.04/24.04 | Python 3.10 |
| check_nfs_mount | >= 2.13.0 | Debian 11/12 | Python 3.9/3.11 |
| check_nfs_mount | >= 2.13.0 | RHEL / Rocky Linux 8/9 | Python 3.8/3.9 |
| check_itop_unassigned_tickets | >= 2.13.0 | Ubuntu 22.04/24.04 | Bash 5.x |
| check_itop_unassigned_tickets | >= 2.13.0 | Debian 11/12 | Bash 5.x |
| check_itop_unassigned_tickets | >= 2.13.0 | RHEL / Rocky Linux 8/9 | Bash 4.x |
| check_cnx_search | >= 2.13.0 | Ubuntu 22.04/24.04 | Bash 5.x |
| check_cnx_search | >= 2.13.0 | Debian 11/12 | Bash 5.x |
| check_cnx_search | >= 2.13.0 | RHEL / Rocky Linux 8/9 | Bash 4.x |
| check_cnx_docs | >= 2.13.0 | RHEL / Rocky Linux 8/9 | Bash 4.x |
| check_cnx_docs | >= 2.13.0 | Ubuntu 22.04/24.04 | Bash 5.x |
| check_cnx_docs | >= 2.13.0 | Debian 11/12 | Bash 5.x |
| check_k8s_pods | >= 2.13.0 | Ubuntu 22.04/24.04 | Python 3.10 |
| check_k8s_pods | >= 2.13.0 | Debian 11/12 | Python 3.9/3.11 |
| check_k8s_pods | >= 2.13.0 | RHEL / Rocky Linux 8/9 | Python 3.8/3.9 |
| check_k8s_workloads | >= 2.13.0 | Ubuntu 22.04/24.04 | Python 3.10 |
| check_k8s_workloads | >= 2.13.0 | Debian 11/12 | Python 3.9/3.11 |
| check_k8s_workloads | >= 2.13.0 | RHEL / Rocky Linux 8/9 | Python 3.8/3.9 |
| check_k8s_nodes | >= 2.13.0 | Ubuntu 22.04/24.04 | Python 3.10 |
| check_k8s_nodes | >= 2.13.0 | Debian 11/12 | Python 3.9/3.11 |
| check_k8s_nodes | >= 2.13.0 | RHEL / Rocky Linux 8/9 | Python 3.8/3.9 |
| check_isds_monitor | >= 2.13.0 | Ubuntu 22.04/24.04 | Bash 5.x |
| check_isds_monitor | >= 2.13.0 | Debian 11/12 | Bash 5.x |
| check_isds_monitor | >= 2.13.0 | RHEL / Rocky Linux 8/9 | Bash 4.x |
| check_isds_replication | >= 2.13.0 | Ubuntu 22.04/24.04 | Bash 5.x |
| check_isds_replication | >= 2.13.0 | Debian 11/12 | Bash 5.x |
| check_isds_replication | >= 2.13.0 | RHEL / Rocky Linux 8/9 | Bash 4.x |
| check_isds_backend | >= 2.13.0 | Ubuntu 22.04/24.04 | Bash 5.x |
| check_isds_backend | >= 2.13.0 | Debian 11/12 | Bash 5.x |
| check_isds_backend | >= 2.13.0 | RHEL / Rocky Linux 8/9 | Bash 4.x |
| check_isds_cert | >= 2.13.0 | Ubuntu 22.04/24.04 | Bash 5.x |
| check_isds_cert | >= 2.13.0 | Debian 11/12 | Bash 5.x |
| check_isds_cert | >= 2.13.0 | RHEL / Rocky Linux 8/9 | Bash 4.x |

## Installation

See the `INSTALL.md` inside each plugin directory for full instructions.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md)

## License

MIT — see [LICENSE](LICENSE)
