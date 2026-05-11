# icinga-plugins

A collection of Icinga 2 monitoring plugins developed by ISW Kudos.

## Available Plugins

| Plugin | Language | Description | Version | Status |
|--------|----------|-------------|---------|--------|
| [check_nfs_mount](plugins/python/check_nfs_mount) | Python | Checks NFS mounts are mounted and accessible | 1.0.0 | Stable |
| [check_itop_unassigned_tickets](plugins/bash/check_itop_unassigned_tickets) | Bash | Checks iTop for unassigned tickets via REST API | 1.0.0 | Stable |
| [check_cnx_search](plugins/bash/check_cnx_search) | Bash | Checks HCL Connections search index freshness | 1.0.0 | Stable |

## Compatibility

| Plugin | Icinga 2 | OS | Lang Version |
|--------|----------|----|--------------|
| check_nfs_mount | >= 2.13.0 | Ubuntu 22.04/24.04 | Python 3.10 |
| check_nfs_mount | >= 2.13.0 | Debian 11/12 | Python 3.9/3.11 |
| check_nfs_mount | >= 2.13.0 | RHEL / Rocky Linux 8/9 | Python 3.8/3.9 |
| check_itop_unassigned_tickets | >= 2.13.0 | Ubuntu 22.04/24.04 | Bash 5.x |
| check_itop_unassigned_tickets | >= 2.13.0 | Debian 11/12 | Bash 5.x |
| check_itop_unassigned_tickets | >= 2.13.0 | RHEL / Rocky Linux 8/9 | Bash 4.x |
| check_cnx_search | >= 2.13.0 | Ubuntu 22.04/24.04 | Bash 5.x |
| check_cnx_search | >= 2.13.0 | Debian 11/12 | Bash 5.x |
| check_cnx_search | >= 2.13.0 | RHEL / Rocky Linux 8/9 | Bash 4.x |

## Installation

See the `INSTALL.md` inside each plugin directory for full instructions.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md)

## License

MIT — see [LICENSE](LICENSE)
