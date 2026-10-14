# Changelog: check_isds_replication

## [Unreleased]

## [1.1.3] - 2026-10-09
### Added
- `icinga2/service_template.conf`: template `isds-replication` (2m / 1m, 3 attempts),
  used by the per-plugin `service.conf` and by the ISDS service set
  (`servicesets/isds`).
### Fixed
- The service now runs on the agent (`command_endpoint = host.name`) and connects
  to `127.0.0.1`. Previously it ran from the master, where neither the IBM LDAP
  client nor the bind password file exists.
- Director instructions use an absolute command path. `$USER1$/...` makes
  Director produce a doubled path.
- Examples bind as a real service account, not `cn=monitor` (which is the search
  base, and fails with LDAP rc=48).
### Documentation
- INSTALL.md states that the check must be applied to every server in the
  topology, because agreement state is only published on the supplier side.
### Changed
- `service.conf` reads the shared `isds_ldap_host`, `isds_ldap_port`,
  `isds_ldap_binddn` and `isds_ldap_passfile` host variables (previously
  `isds_repl_binddn` / `isds_repl_passfile`), so one account and one password file
  configure both LDAP checks. Hosts configured with the old names must be updated.

## [1.1.2] - 2026-06-26
### Added
- Read `ibm-replicationonhold` (present on both supplier and consumer agreement
  entries) and alert CRITICAL when an agreement is administratively on hold — the
  reliable cross-side signal, where `ibm-replicationState` exists only on the
  supplier side.
### Changed
- Peer/consumer-side agreements (no local operational status) are now reported as
  an informational OK ("no live status on this host; verify on the supplier")
  instead of a hollow "healthy", and no longer emit a `pending_changes=U` metric.
### Fixed
- Avoid an unbound-variable error under `set -u` on bash <= 4.3 when no
  per-agreement pending perfdata is emitted.

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
