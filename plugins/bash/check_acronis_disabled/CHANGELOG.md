# Changelog: check_acronis_disabled

## [Unreleased]

## [1.0.1] - 2026-07-23
### Fixed
- **False "tray running" positive.** The tray check now identifies the process by
  its `argv[0]` (the launched executable), read from `/proc/<pid>/cmdline`, instead
  of matching the tray path anywhere in a command line with `pgrep -f`. Icinga
  passes the tray path to the plugin via `--tray-bin`, so the path also appears in
  the command line of the check script and its `sudo`/`timeout`/`pgrep` helpers —
  and `pgrep -f` matched those, reporting a phantom tray. An earlier attempt to
  exclude the plugin's own process group did not hold, because `timeout` (and
  `sudo`) relocate themselves into a new process group. Matching on `argv[0]`
  cannot match a wrapper (whose `argv[0]` is `bash`/`sudo`/`timeout`/`pgrep`),
  regardless of process group. Detection is via world-readable
  `/proc/<pid>/cmdline`, so it still needs no root.
### Changed
- The tray check no longer shells out to `pgrep`/`ps` (dependencies dropped); it
  scans `/proc` directly. `systemctl`, `awk`, and `timeout` remain the only
  external dependencies.

## [1.0.0] - 2026-07-22
### Added
- Initial release. Read-only safety-net check verifying two deliberately-disabled
  Acronis Cyber Protect (IONOS Cloud Backup) components stay disabled on headless
  AlmaLinux 9 hosts.
- `cyber-protect-service` (systemd): WARN if `is-active` reports running or
  `is-enabled` reports enabled; `disabled`/`masked`/`static` are treated as good.
- `cyber-desktop-service` (aakore-managed unit + process): WARN if the tray
  process (`cyber-desktop-service-qt6`) is running or the **local** aakore unit
  `STAT` starts with `+`. The cloud-registration reference row (`STAT` exactly
  `+X`) is excluded.
- **WARNING-only** design — a re-enabled component is policy drift, not an outage,
  so the plugin never emits CRITICAL. Worst-state precedence is OK < UNKNOWN <
  WARNING, so a confirmed re-enable is never masked by an indeterminate result.
- Graceful degradation:
  - Agent not installed (no aakore CLI and systemd unit unknown) → OK with a note,
    so the check is safe to apply broadly.
  - aakore unreachable / not root → falls back to the tray process check and notes
    the config state as unavailable; does not flap to a hard state.
- UNKNOWN reserved for genuine inability to determine state (e.g. `systemctl`
  timeout) or a missing required command.
- Boolean performance data (`1` = re-enabled) for both components.
- Overridable names/paths via `--service`, `--unit`, `--tray-bin`, `--aakore`,
  and a `-t` timeout.
