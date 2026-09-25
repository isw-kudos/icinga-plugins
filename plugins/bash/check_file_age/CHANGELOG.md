# Changelog: check_file_age

## [Unreleased]

## [1.0.0] - 2026-09-25
### Added
- Initial release
- Age of the newest file matching a glob, with `-w`/`-c` thresholds in hours
- Absence detection: no matching file, and a missing directory, are CRITICAL,
  while an unreadable directory is UNKNOWN so the two can never be confused
- `--min-bytes` catches a truncated or zero-byte file that is otherwise fresh
- Performance data: `age_seconds`, `matched_files`, `newest_bytes`
