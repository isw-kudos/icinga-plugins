# Changelog: check_nfs_mount

## [Unreleased]

## [1.0.1] - 2026-08-14
### Fixed
- Plugin now runs on Python 3.6, the stock `python3` on RHEL / Rocky / AlmaLinux 8.
  Previously `from __future__ import annotations` caused a compile-time
  `SyntaxError: future feature annotations is not defined`, so the check failed
  before executing a single line on any node whose `python3` was older than 3.7.

### Changed
- Removed `from __future__ import annotations`
- Builtin generic annotations (`dict[...]`, `list[...]`, `tuple[...]`) replaced with
  `typing.Dict` / `typing.List` / `typing.Tuple` equivalents
- Minimum supported Python lowered from 3.8 to 3.6 in README.md and INSTALL.md

No behaviour, argument, or output-format changes.

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
