# Changelog: check_isds_cert

## [Unreleased]

## [1.1.0] - 2026-06-26
### Added
- Auto-locate the GSKit cert tool under common install dirs (e.g. `/opt/db2/*/gskit/bin`) in addition to PATH, with a `--gsk-bin` override and an LD_LIBRARY_PATH for the GSKit libs - so it works off the icinga user's PATH.
- `--all-certs` to also check trusted CA roots (default now checks personal certs only).
### Fixed
- Parse the GSKit 8 / ISVD 10.x "Not After : YYYY M D HH:MM:SS" validity-date format when computing days-to-expiry.
- Correctly parse quoted certificate labels from `gsk -cert -list` (labels containing `-`, e.g. "… - G3", are no longer mis-handled).
### Changed
- Default now checks only PERSONAL certs (the cert the server presents). Keystores usually also bundle CA roots, several often long-expired, which previously caused false CRITICALs. Use `--all-certs` for the old behavior.

## [1.0.0] - 2026-06-25
### Added
- Initial release
- Reads TLS certificate expiry from a GSKit CMS keystore (.kdb) on the SDS host
- Locates the GSKit cert tool (gsk8capicmd_64, gsk8capicmd, or idsgskcapicmd)
- Unlocks the keystore via stash file (`--stash`, preferred) or password
  (`--password`, discouraged)
- Checks all certs by default and reports the soonest to expire, or a single
  `--label`
- Day-based warning/critical thresholds (`-w` / `-c`)
- Performance data per cert (`days_until_expiry_<label>`) plus overall
  `min_days_until_expiry`
