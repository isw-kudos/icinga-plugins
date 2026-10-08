# Changelog: check_cnx_search

## [Unreleased]

## [1.0.1] - 2026-10-06
### Fixed
- Plugin exited silently with no output when the response was not XML (e.g. an
  http:// URL redirecting to https://, or a login page), because the failing
  xmllint call tripped set -e
- HTTP 3xx redirects are now reported as UNKNOWN with the redirect target

## [1.0.0] - 2025-01-01
### Added
- Initial release
- Checks HCL Connections search index freshness via Atom feed
- Supports -H, -u, -p, -w, -c, -t arguments
- Performance data output: age in seconds with warn/crit thresholds
- Timeout detection with UNKNOWN exit (curl exit code 28)
- Unique temp files to support parallel check execution
