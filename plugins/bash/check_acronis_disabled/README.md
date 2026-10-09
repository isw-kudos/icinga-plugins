# check_acronis_disabled

Verifies that two **Acronis Cyber Protect** (IONOS Cloud Backup) components stay
**disabled** on headless AlmaLinux 9 servers, where our Ansible role deliberately
turns them off. A cloud-side "pull", an agent update, or a manual change can
silently re-enable them — this check is the safety net that tells us when that
happens.

Because a re-enabled component is **policy drift, not an outage**, the check
returns **WARNING** (never CRITICAL) when either component is back. It is
**read-only** and never stops, starts, or disables anything.

## Components checked

| Component               | Type                          | Good ("disabled") state                                  |
|-------------------------|-------------------------------|----------------------------------------------------------|
| `cyber-protect-service` | systemd service               | Not running **and** not enabled at boot                  |
| `cyber-desktop-service` | aakore-managed unit + process | aakore local unit disabled **and** tray process not running |

`cyber-protect-service` is checked with `systemctl is-active` / `systemctl
is-enabled`. `cyber-desktop-service` is **not** a systemd service — it is a unit
launched and supervised by the Acronis agent core (`aakore`), so it is inspected
by scanning `/proc` for a process whose executable (`argv[0]`) is the tray binary
(`cyber-desktop-service-qt6`) and by reading `aakore units` (the managed-unit
state). In `aakore units` the local row's `STAT` starts with
`+` when enabled and `-` when disabled; the cloud-registration reference row
(`STAT` exactly `+X`) is ignored.

## Requirements
- Icinga 2 >= 2.13.0
- Bash >= 4.x
- Runs **locally** on the host running the Acronis agent
- Linux with `/proc` (used for tray-process detection) — always true on AlmaLinux 9
- `systemctl`, `awk`, `timeout` (coreutils) — all present on a stock AlmaLinux 9
- **root** to read the aakore unit state (`aakore units`). Without root the
  plugin falls back to the tray process check and notes the config state as
  unavailable — see [INSTALL.md](INSTALL.md).

## Compatibility
See Compatibility Matrix below.

## Usage
```
check_acronis_disabled [--service NAME] [--unit NAME] [--tray-bin PATH] \
                       [--aakore PATH] [-t timeout] [-V] [-h]
```

All arguments are optional; the defaults match a stock Acronis agent install.

## Arguments

| Argument     | Required | Default                                       | Description                                     |
|--------------|----------|-----------------------------------------------|-------------------------------------------------|
| --service    | No       | `cyber-protect-service.service`               | systemd unit for `cyber-protect-service`        |
| --unit       | No       | `cyber-desktop-service`                        | aakore unit name for the desktop/tray component |
| --tray-bin   | No       | `/opt/acronis/bin/cyber-desktop-service-qt6`  | Tray binary, matched as a process `argv[0]`     |
| --aakore     | No       | `/opt/acronis/aakore`                          | Path to the Acronis agent core CLI              |
| -t           | No       | 30                                            | Timeout per external command (seconds)          |
| -V           | No       |                                               | Show version                                    |
| -h           | No       |                                               | Show help                                       |

## Exit codes
`0` OK · `1` WARNING · `3` UNKNOWN. **CRITICAL (2) is never emitted.**

- **WARNING** — either component is running or enabled (it has come back).
- **UNKNOWN** — a genuine inability to determine state (e.g. `systemctl` timed
  out). `cyber-protect-service` re-enabled (WARNING) always outranks an
  indeterminate desktop sub-result, so the actionable signal is never masked.
- **OK** — both disabled, *or* the agent is not installed (safe to apply broadly).

## Example Output
OK:
```
check_acronis_disabled OK - cyber-protect-service inactive/disabled; cyber-desktop-service disabled (STAT -Tr), tray not running | cyber_protect_active=0;1;;0;1 cyber_protect_enabled=0;1;;0;1 cyber_desktop_tray=0;1;;0;1 cyber_desktop_unit_enabled=0;1;;0;1
```
WARNING (tray came back):
```
check_acronis_disabled WARNING - cyber-protect-service inactive/disabled; cyber-desktop-service disabled (STAT -Tr), tray running (pid 12345) | cyber_protect_active=0;1;;0;1 cyber_protect_enabled=0;1;;0;1 cyber_desktop_tray=1;1;;0;1 cyber_desktop_unit_enabled=0;1;;0;1
```
Agent absent:
```
check_acronis_disabled OK - Acronis agent not installed - nothing to check
```

Each perfdata metric is boolean where **`1` = bad** (re-enabled), with warn
threshold `1`, so the emitted graph makes a re-enable event obvious.

## Known Limitations
- **aakore needs root.** Run the plugin as root or via a narrow `sudo` rule (see
  INSTALL.md). Without it, the aakore unit state cannot be read; the plugin falls
  back to the tray *process* check and notes `aakore unit state unavailable` —
  it will still WARN if the tray is running, and it will not flap to a hard state
  if the core is simply down.
- **Names/paths vary by agent version.** The systemd unit, the aakore unit name,
  and the tray binary path are all overridable (`--service`, `--unit`,
  `--tray-bin`, `--aakore`). Confirm them against your install if a check reports
  the component as absent unexpectedly.
- The tray is detected by matching a process's `argv[0]` against the tray binary
  (via `/proc/<pid>/cmdline`), **not** by grepping the whole command line. This is
  deliberate: Icinga passes the tray path in the plugin's own command line
  (`--tray-bin`), so a `pgrep -f`-style match would count the check itself (and its
  `sudo`/`timeout` helpers) as a running tray. A consequence is that if the tray is
  ever launched such that the binary is **not** its `argv[0]` (e.g. via an
  interpreter/wrapper that keeps its own name in `argv[0]`), it will not be
  detected — not a concern for the stock aakore-launched tray.
- Point-in-time check; pair with Icinga's state history to see when a component
  came back.

## Compatibility Matrix

| Plugin Version | Icinga 2 Version | OS                     | Lang Version |
|----------------|------------------|------------------------|--------------|
| 1.0.1          | >= 2.13.0        | RHEL / Rocky / AlmaLinux 8/9 | Bash 4.x |
| 1.0.1          | >= 2.13.0        | Ubuntu 22.04/24.04     | Bash 5.x     |
| 1.0.1          | >= 2.13.0        | Debian 11/12           | Bash 5.x     |

Primary target is **AlmaLinux 9**. The plugin only depends on `systemctl`,
`/proc`, `awk`, and `timeout`, so it runs on any systemd/Linux distro with the
Acronis agent installed.

## License
MIT - see LICENSE
