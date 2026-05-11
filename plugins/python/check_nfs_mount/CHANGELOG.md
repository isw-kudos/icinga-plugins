# Changelog: check_nfs_mount

## [Unreleased]

## [1.0.0] - 2025-01-01
### Added
- Initial release
- Checks one or more NFS mount points via /proc/mounts and stat()/listdir()
- SIGALRM-based timeout per mount to detect stale/hung mounts
- Optional write check (-w) using a pid-scoped temp file
- Verbose mode (-v) to show OK mount detail in output
- Performance data: response time in ms per mount point
- Multiple mount points via repeated -m flag

### Changed (from original)
- Renamed TimeoutError class to MountTimeoutError (avoids shadowing Python built-in)
- Removed unused pathlib.Path import
- Output format aligned to project standard: PLUGINNAME STATE - message
- Perfdata placed on first output line (summary line) for correct Icinga 2 parsing
- Exit code variables renamed to STATE_OK, STATE_WARNING, STATE_CRITICAL, STATE_UNKNOWN
