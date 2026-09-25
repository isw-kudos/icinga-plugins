# Changelog: check_itop_cron

## [Unreleased]

## [1.0.0] - 2026-09-25
### Added
- Initial release
- Counts `priv_async_task` rows still `planned` more than `--stale-hours` past
  their scheduled time
- `--planned-column` because the column is `planned` on some iTop versions and
  `planned_date` on others; a wrong name fails loudly as UNKNOWN
- Credentials via `--defaults-file` or `--password-file` only — there is no `-p`
  option, so the password never reaches the process list
- Fails closed: every connection, permission or schema error is UNKNOWN
- `-c` is unset by default, so the check never goes CRITICAL unless asked
- Performance data: `overdue_tasks`, `oldest_overdue_hours`
