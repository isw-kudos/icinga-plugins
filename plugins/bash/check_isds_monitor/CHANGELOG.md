# Changelog: check_isds_monitor

## [Unreleased]

## [1.0.0] - 2026-06-25
### Added
- Initial release
- Reads SDS `cn=monitor` over LDAP (idsldapsearch or ldapsearch)
- Sub-checks: worker pool exhaustion, current connections, throughput counters,
  cache hit ratios — each individually toggleable
- TLS support via `--ldaps` and `-Z` (StartTLS)
- Password supplied via file (`-y`) to avoid process-list exposure
- Performance data output for all collected metrics
