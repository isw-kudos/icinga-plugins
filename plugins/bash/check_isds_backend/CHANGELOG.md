# Changelog: check_isds_backend

## [Unreleased]

## [1.0.2] - 2026-06-26
### Fixed
- Strip the CLP `db2 => ` / `db2 (cont.) => ` prompt that the stdin session prints
  inline before the first result line. Previously the first tablespace row (and a
  lone scalar like the log %) was prefixed and silently dropped — so the busiest
  tablespace went unmonitored and `db2-logs` reported UNKNOWN.
### Changed
- Tablespace alerting is now **auto-resize-aware**: `TBSP_UTILIZATION_PERCENT` is
  measured against *current* allocation, so an auto-resize tablespace with no max
  (`TBSP_MAX_SIZE = -1`) can sit near 100% while healthily auto-extending. Such
  tablespaces are now emitted as perfdata (informational) and not alerted on;
  warn/crit apply only to fixed tablespaces (and auto-resize with a finite max).
  Prevents a false CRITICAL on e.g. SYSCATSPACE at 95% on automatic-storage DBs.

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
