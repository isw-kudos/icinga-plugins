# Changelog: check_isds_replication

## [Unreleased]

## [1.1.1] - 2026-06-26
### Fixed
- Unfold LDIF line continuations (RFC 2849) before parsing. IBM `idsldapsearch -L`
  wraps lines longer than ~77 chars with a leading-space continuation, so long
  replication agreement DNs were read truncated and the per-agreement lookup
  failed with `Invalid DN syntax` (rc=34). DNs are now reassembled before use.

## [1.1.0] - 2026-06-26
### Added
- Support for IBM `idsldapsearch` flag syntax (`-h/-p/-L/-w`) in addition to
  OpenLDAP `ldapsearch` (`-H/-x/-LLL/-y`), auto-detected by client flavor
- Auto-location of the SDS client under `/opt/*/ldap/*/bin` when not on PATH
- New options: `--ldapsearch-bin`, `--ldap-flavor`, `--key-file`, `--key-pw`
### Fixed
- No longer requires OpenLDAP `ldapsearch`; works with the SDS-bundled IBM client
  out of the box (previously the OpenLDAP-only flags failed against idsldapsearch)

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
