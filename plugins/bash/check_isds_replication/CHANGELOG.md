# Changelog: check_isds_replication

## [Unreleased]

## [1.0.0] - 2026-06-25
### Added
- Initial release
- Enumerates SDS replication agreements (`objectclass=ibm-replicationAgreement`)
  under a configurable base over LDAP (idsldapsearch or ldapsearch)
- Per-agreement checks: state (suspended/on hold/error), last result code,
  pending-change backlog (`-w`/`-c`), and optional last-change lag
  (`--lag-warn`/`--lag-crit`)
- `--agreement` filter (repeatable) to restrict checks to specific agreements
- UNKNOWN when no agreements are found, rather than a false OK
- TLS support via `--ldaps` and `-Z` (StartTLS)
- Password supplied via file (`-y`) to avoid process-list exposure
- Per-agreement performance data: `agreements_ok`, `agreements_error`,
  `pending_changes_<cn>`, and `replication_lag_seconds_<cn>` when available
