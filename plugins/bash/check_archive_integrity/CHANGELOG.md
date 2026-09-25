# Changelog: check_archive_integrity

## [Unreleased]

## [1.0.0] - 2026-09-25
### Added
- Initial release
- Decompression test of the newest matching archive (`gzip`, `bzip2`, `xz`,
  `zip`, and `tar -tzf`/`-tjf`/`-tJf` for tarballs)
- Checksum sidecar presence check, reported as WARNING rather than CRITICAL:
  a valid archive with no sidecar is a script regression, not a missing backup
- `--min-age-seconds` never tests an archive that may still be being written,
  which removes the dependency on being scheduled outside the backup window
- Severity ladder ordered CRITICAL > WARNING > UNKNOWN so an unreadable sidecar
  cannot mask a corrupt archive
- Performance data: `archive_bytes`, `tested_age_seconds`, `integrity_ok`,
  `sidecar_present`
