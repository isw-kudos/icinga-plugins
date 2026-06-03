# check_cnx_docs

Checks the health of an HCL Connections Docs **Conversion** server (the
Symphony / LibreOffice stack that renders documents into preview-ready
formats). Two sub-checks:

1. **sym_monitor** — the `sym_monitor` watchdog process is running.
   Includes a configurable grace window (default 300 s) to suppress
   alerts during a cron-driven restart, so a brief absence between
   crash and the next cron tick stays silent.
2. **soffice** — the number of `soffice` worker processes matches the
   expected count, autodetected from
   `/opt/Conversion/symphony/sym_monitor/instances.cfg` (one non-empty
   line per expected instance).

When `sym_monitor` accumulates errors and dies, the `soffice` workers
are no longer restarted and document conversion fails silently for end
users. This plugin surfaces both the cause (watchdog gone) and the
symptom (worker count below expected).

## Requirements

- Icinga 2 >= 2.13.0
- Bash >= 4.x
- `pgrep` (from `procps` / `procps-ng`)
- `grep`, `timeout` (GNU coreutils — Linux only)
- HCL Connections Docs Conversion server with a populated
  `instances.cfg`
- The user running the check must be able to:
  - read `instances.cfg`
  - see processes from other users via `ps` / `pgrep` (default on Linux
    unless `/proc` is mounted with `hidepid=2`)

## Compatibility

See Compatibility Matrix below.

## Usage

```
check_cnx_docs [--instances-cfg PATH]
               [--sym-monitor-pattern PAT] [--soffice-pattern PAT]
               [--sym-monitor-grace-seconds N] [--state-file PATH]
               [--no-sym-monitor] [--no-soffice]
               [-t SECONDS] [-V] [-h]
```

## Arguments

| Argument                        | Required | Default                                            | Description |
|---------------------------------|----------|----------------------------------------------------|-------------|
| `--instances-cfg`               | No       | `/opt/Conversion/symphony/sym_monitor/instances.cfg` | Source of expected soffice count (non-empty line count) |
| `--sym-monitor-pattern`         | No       | `sym_monitor`                                      | `pgrep -f` pattern for the watchdog |
| `--soffice-pattern`             | No       | `soffice`                                          | `pgrep -f` pattern for the workers |
| `--sym-monitor-grace-seconds`   | No       | 300                                                | Suppress CRITICAL while sym_monitor has been down for ≤ N seconds (covers the cron-restart window). Set to 0 to disable. |
| `--state-file`                  | No       | `/tmp/check_cnx_docs.state`                        | Path to the state file used to remember when sym_monitor was first seen down |
| `--no-sym-monitor`              | No       |                                                    | Disable the sym_monitor sub-check |
| `--no-soffice`                  | No       |                                                    | Disable the soffice sub-check |
| `-t` / `--timeout`              | No       | 30                                                 | Per-operation timeout in seconds |
| `-V` / `--version`              | No       |                                                    | Show plugin version |
| `-h` / `--help`                 | No       |                                                    | Show help |

## Example Output

OK — both watchdog and workers running, expected count of 3:

```
check_cnx_docs OK - sym_monitor=OK soffice=OK | sym_monitor_procs=1 sym_monitor_down_seconds=0;300;300;0 soffice_procs=3;3;; soffice_expected=3
[OK] sym_monitor: 1 process(es) running
[OK] soffice: 3 of 3 expected processes running (from instances.cfg)
```

OK during the sym_monitor grace window (watchdog gone, cron restart pending):

```
check_cnx_docs OK - sym_monitor=OK soffice=CRIT | sym_monitor_procs=0 sym_monitor_down_seconds=42;300;300;0 soffice_procs=0;3;; soffice_expected=3
[OK] sym_monitor: no process found, down for 42s (within 300s grace - cron restart pending)
[CRIT] soffice: 0 of 3 expected processes running (from instances.cfg)
```

(Note: soffice will still report CRITICAL since workers can't be running
when sym_monitor isn't there to spawn them. If that's noisy, set the
same grace via `--no-soffice` for the restart window, or raise
`max_check_attempts` for the service in Icinga.)

CRITICAL — workers gone, watchdog down beyond grace window:

```
check_cnx_docs CRITICAL - sym_monitor=CRIT soffice=CRIT | sym_monitor_procs=0 sym_monitor_down_seconds=520;300;300;0 soffice_procs=0;3;; soffice_expected=3
[CRIT] sym_monitor: no process matching 'sym_monitor' found, down for 520s (exceeded 300s grace)
[CRIT] soffice: 0 of 3 expected processes running (from instances.cfg)
```

WARNING — partial worker outage:

```
check_cnx_docs WARNING - sym_monitor=OK soffice=WARN | sym_monitor_procs=1 soffice_procs=1;3;; soffice_expected=3
[OK] sym_monitor: 1 process(es) running
[WARN] soffice: 1 of 3 expected processes running (from instances.cfg)
```

UNKNOWN — can't autodetect expected count:

```
check_cnx_docs UNKNOWN - sym_monitor=OK soffice=UNKNOWN | sym_monitor_procs=1 soffice_procs=U soffice_expected=U
[OK] sym_monitor: 1 process(es) running
[UNKNOWN] soffice: instances.cfg not found at /opt/Conversion/symphony/sym_monitor/instances.cfg - cannot determine expected count
```

## Performance Data

| Label                       | UOM | Description |
|-----------------------------|-----|-------------|
| `sym_monitor_procs`         |     | Number of sym_monitor processes found |
| `sym_monitor_down_seconds`  | s   | How long sym_monitor has been down (0 when up). Warn/crit thresholds = grace window so overshoot shows in graphs |
| `soffice_procs`             |     | Number of soffice processes found. Warn threshold equals expected so any shortfall shows in graphs |
| `soffice_expected`          |     | Expected soffice count autodetected from instances.cfg — handy for trending capacity changes |

## Known Limitations

- Linux-only — uses `pgrep`, `timeout`, and procfs semantics from
  GNU coreutils / procps.
- The soffice sub-check requires `instances.cfg` to be readable. If it
  is owned by a service user with restrictive permissions, set a group
  ACL granting read access to the Icinga agent user (see INSTALL.md).
- Default patterns (`sym_monitor`, `soffice`) are deliberately broad.
  On systems with other processes whose command lines contain those
  strings, use `--sym-monitor-pattern` / `--soffice-pattern` to tighten
  the match (e.g. `/opt/Conversion/.*soffice`).
- The grace window only applies to **sym_monitor**, not to soffice. If
  the watchdog crashes and is gone for a few minutes, soffice will also
  go to zero and that sub-check will report CRITICAL until the workers
  respawn. See INSTALL.md "Grace period" for alternatives if that's
  noisy in your environment.
- The state file (`/tmp/check_cnx_docs.state` by default) is wiped on
  reboot. That's fine: post-reboot sym_monitor is started fresh from
  boot scripts, so a wiped state file just means the grace window
  restarts cleanly.

## Compatibility Matrix

| Plugin Version | Icinga 2 Version | OS                     | Lang Version |
|----------------|------------------|------------------------|--------------|
| 1.0.0          | >= 2.13.0        | RHEL / Rocky Linux 8/9 | Bash 4.x     |
| 1.0.0          | >= 2.13.0        | Ubuntu 22.04/24.04     | Bash 5.x     |
| 1.0.0          | >= 2.13.0        | Debian 11/12           | Bash 5.x     |

## License

MIT — see [LICENSE](../../../LICENSE)
