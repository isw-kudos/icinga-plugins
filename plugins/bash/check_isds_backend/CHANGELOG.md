# Changelog: check_isds_backend

## [Unreleased]

## [1.0.1] - 2026-06-26
### Fixed
- DB2 sub-checks now run `CONNECT` + query in a **single** CLP session (statements
  fed to `db2 -x -t` on stdin) instead of two chained `db2` invocations, which under
  a non-interactive `su -c` did not share the connection and failed with `SQL1024N`.
- Tablespace SQL filters `TBSP_UTILIZATION_PERCENT >= 0`, dropping system temporary
  tablespaces (which report `-1`, not a real utilization).
- Transaction-log parsing takes the lone-integer result line, robust against the
  CLP welcome banner / connection-info block now present in the output.
- `sanitize` lowercases via `tr` instead of `${var,,}` (portable; bash 3.2+).

## [1.0.0] - 2026-06-25
### Added
- Initial release
- Runs locally on the SDS host; complements check_isds_monitor
- Sub-checks (each individually toggleable):
  - `proc` - ibmslapd / db2sysc liveness (CRITICAL if down) and ibmdiradm
    (WARNING by default, CRITICAL with `--diradm-crit`, skippable with `--no-diradm`)
  - `db2-tablespace` - DB2 tablespace utilization % via SYSIBMADM.TBSP_UTILIZATION
  - `db2-logs` - DB2 transaction-log utilization % via MON_GET_TRANSACTION_LOG
- Sub-check selection via `--no-<name>` toggles and an allowlist `--check <name>`
- Optional `--db2-user` to run DB2 commands as the instance owner via `su`
- Graceful degradation: missing db2 binary, missing instance/db args, or su
  failures yield UNKNOWN for that sub-check instead of crashing
- Performance data for process counts, per-tablespace utilization, and log utilization
