# Changelog: check_isds_monitor

## [Unreleased]

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
