# Changelog: check_domino_mail

## [Unreleased]

## [1.0.0] - 2025-01-01
### Added
- Initial release
- Seven independent sub-checks: status, nrpc_tcp, nrpc_handshake, show_server,
  nrpc_trace, smtp, http
- SIGALRM-free timeout via Python socket for NRPC handshake (compatible with
  Icinga agent's multi-threaded environment)
- RST classified as healthy in NRPC handshake (proves NRPC thread is alive)
- Automatic retry with WARNING on transient NRPC handshake failure
- Domino Availability Index parsing (NOT_AVAILABLE → CRIT, RESTRICTED → WARN)
- Per-sub-check performance data in ms
- All sub-checks independently toggleable via --no-X flags
- Requires Nashcom Domino start script for 'domino cmd' output capture

### Changed (from original)
- set -u → set -euo pipefail; fixed incompatible patterns (|| DOMINO_RC=$? etc.)
- Exit code variables renamed to STATE_OK / STATE_WARNING / STATE_CRITICAL / STATE_UNKNOWN
- Output prefix changed from DOMINO to check_domino_mail (project standard)
- Added -V / --version flag and PLUGIN_NAME / PLUGIN_VERSION variables
- MIT license header added
