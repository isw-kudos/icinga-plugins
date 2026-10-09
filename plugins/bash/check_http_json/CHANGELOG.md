# Changelog: check_http_json

## [Unreleased]

## [1.1.0] - 2026-07-20
### Added
- `--expect` now accepts bare key paths (e.g. `route`, `data.route`) by
  auto-prefixing the jq `.`; dotted paths and full jq expressions still work

### Fixed
- A `--expect` filter that fails to compile now reports UNKNOWN with the jq
  error, instead of the misleading "missing or null" CRITICAL

## [1.0.0] - 2026-07-20
### Added
- Initial release
- Fetches a URL over HTTP(S) and validates JSON fields
- Repeatable `--expect '<jq-path>=<value>'` field checks (at least one required)
- Repeatable `--header` for custom request headers (vhost routing, auth, etc.)
- `-k`/`--insecure` to skip TLS certificate verification (verified by default)
- CRITICAL on field mismatch, non-2xx HTTP status, connection failure, or
  non-JSON body; UNKNOWN on timeout or argument errors
- `-t` timeout handling and `time`/`checks` performance data
