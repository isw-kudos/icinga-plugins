# Changelog: check_ionos_nfs_usage

## [Unreleased]

## [1.0.0] - 2026-10-26
### Added
- Initial release
- Reads an IONOS Cloud NFS cluster and all of its shares from the NFS API v1,
  adds up the share usage, and compares it with the cluster's provisioned size
- Alerts on the larger of the share total and the cluster's own reported usage
- `-w` / `-c` thresholds as a percentage of the cluster size (default 80 / 90)
- `-L` location or `-U` base URL; `-C` cluster by ID or name, optional when the
  location has a single cluster
- API token from `--token-file` or `IONOS_TOKEN`; deliberately no option that
  takes the token on the command line
- Per-share breakdown with quotas in the long output
- Performance data: `used`, `used_pct`, `shares_used`, `cluster_used`, and one
  `share_<name>` per share
- UNKNOWN on API errors, unreachable API, timeout, missing usage data, and
  argument errors (argparse errors exit 3, not 2)
- Runs on Python 3.6 (RHEL / Rocky / AlmaLinux 8 stock `python3`)
