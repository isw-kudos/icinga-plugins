# Changelog: check_isds_monitor

## [Unreleased]

## [1.1.3] - 2026-10-09
### Added
- `icinga2/service_template.conf`: template `isds-monitor` (1m / 30s, 3 attempts),
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
### Changed
- `service.conf` reads the shared `isds_ldap_host`, `isds_ldap_port`,
  `isds_ldap_binddn` and `isds_ldap_passfile` host variables (previously
  `isds_monitor_binddn` / `isds_monitor_passfile`), so one account and one password file
  configure both LDAP checks. Hosts configured with the old names must be updated.

## [1.1.2] - 2026-06-26
### Fixed
- Unfold LDIF line continuations (RFC 2849) before parsing, so long folded
  attribute values from `idsldapsearch -L` are read intact. Shared hardening with
  check_isds_replication; no behaviour change for the short `cn=monitor` values.

## [1.1.1] - 2026-06-26
### Fixed
- Corrected `cn=monitor` cache attribute names for SDS / ISVD 10.x: derive the
  hit ratio from `*_hit`/`*_miss` (`hit/(hit+miss)`) instead of the non-existent
  `*_hits`/`*_tries`. ACL cache dropped (the server exposes no hit/miss for it).
- Throughput: use `searchescompleted` (was `searchcompleted`) so the
  `searches_completed` counter is emitted again.
### Changed
- Cache hit-ratio alerting is now opt-in (default off). Filter caches legitimately
  run a low hit ratio, so ratios are emitted as perfdata and only alert when
  `--cache-warn`/`--cache-crit` are set.

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
- Reads SDS `cn=monitor` over LDAP (idsldapsearch or ldapsearch)
- Sub-checks: worker pool exhaustion, current connections, throughput counters,
  cache hit ratios — each individually toggleable
- TLS support via `--ldaps` and `-Z` (StartTLS)
- Password supplied via file (`-y`) to avoid process-list exposure
- Performance data output for all collected metrics
