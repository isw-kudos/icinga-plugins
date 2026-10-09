# Changelog: check_itop_replica_errors

## [Unreleased]

## [1.0.0] - 2026-09-25
### Added
- Initial release
- Counts replicas per data source using `SUM(status_last_error <> '')`, the only
  reliable error signal on `priv_sync_replica` — the `status` enum has no
  `'error'` member, so a check written against it can never fire
- Baseline comparison per source (`--baseline`, `--baseline-default`), because
  a stable pre-existing fault would otherwise alert permanently and be muted
- Reports, without alerting, when a source falls below its recorded baseline —
  a baseline left too high silently absorbs the next regression
- `--ignore-source` for data sources that are dead by design
- Credentials via `--defaults-file` or `--password-file` only; no `-p` option
- Fails closed: every connection, permission or schema error is UNKNOWN
- Performance data: `replica_errors_<id>` (baseline in the warn field),
  `replica_errors_total`, `replica_errors_above_baseline`
