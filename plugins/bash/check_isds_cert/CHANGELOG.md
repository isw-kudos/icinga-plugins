# Changelog: check_isds_cert

## [Unreleased]

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
