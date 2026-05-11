# Changelog: check_cnx_search

## [Unreleased]

## [1.0.0] - 2025-01-01
### Added
- Initial release
- Checks HCL Connections search index freshness via Atom feed
- Supports -H, -u, -p, -w, -c, -t arguments
- Performance data output: age in seconds with warn/crit thresholds
- Timeout detection with UNKNOWN exit (curl exit code 28)
- Unique temp files to support parallel check execution
