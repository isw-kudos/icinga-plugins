# Changelog: check_cnx_docs

## [Unreleased]

## [1.0.0] - 2026-06-03
### Added
- Initial release
- `sym_monitor` sub-check — verifies the sym_monitor watchdog process is
  running (CRITICAL when absent, with a configurable grace window to
  suppress alerts during a cron-driven restart)
- `soffice` sub-check — verifies the running soffice count matches the
  expected count autodetected from
  `/opt/Conversion/symphony/sym_monitor/instances.cfg` (one non-empty
  line per expected instance). CRITICAL when zero running, WARNING when
  below expected, OK when at or above expected.
- Grace window for sym_monitor (default 300 s) backed by a state file
  (`/tmp/check_cnx_docs.state` by default). Configurable via
  `--sym-monitor-grace-seconds` (set to 0 to disable) and `--state-file`.
- Configurable paths and pgrep patterns (`--instances-cfg`,
  `--sym-monitor-pattern`, `--soffice-pattern`)
- Per-sub-check toggles (`--no-sym-monitor`, `--no-soffice`)
- Performance data: `sym_monitor_procs`, `sym_monitor_down_seconds`
  (with grace as warn/crit thresholds), `soffice_procs` (with expected
  count as warn threshold), `soffice_expected`
