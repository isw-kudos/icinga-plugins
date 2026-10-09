# check_itop_replica_errors

Counts iTop synchro replicas carrying an error, grouped by data source, and
compares each source against a **recorded baseline**.

## Two things this check does differently

**It counts `status_last_error <> ''`, not `status = 'error'`.**
`priv_sync_replica.status` is an enum of
`('modified','new','obsolete','orphan','synchronized')` — there is no `'error'`
member. A check written against `status = 'error'` returns zero rows forever and
looks *exactly* like a healthy result. That is the silent false-green this
plugin exists to avoid, so the test suite asserts the difference explicitly.

**It alerts above a baseline, not above zero.** Real estates carry stable,
understood, pre-existing synchro faults — field mastering problems, non-unique
reconciliation keys — that produce a constant non-zero count. Alerting on
non-zero would alert permanently, and a permanent alert is muted within a week.

## Requirements
- Icinga 2 >= 2.13.0
- Bash >= 4.x (uses associative arrays)
- `mysql` or `mariadb` client, and `timeout`
- TCP access to the iTop database and a read-only user — see
  [INSTALL.md](INSTALL.md)

## Compatibility
See Compatibility Matrix below.

## Usage
```
check_itop_replica_errors [-H <host>] [-P <port>] [-d <database>]
                          [--defaults-file <path> | --password-file <path>] [-u <user>]
                          [--baseline '<id>=<n>,...'] [--baseline-default <n>]
                          [--ignore-source <id,...>] [-w <n>] [-c <n>]
                          [-t <seconds>] [-V] [-h]
```

## Arguments

| Argument             | Required | Default   | Description                                                      |
|----------------------|----------|-----------|------------------------------------------------------------------|
| -H                   | No       | 127.0.0.1 | Database host                                                    |
| -P                   | No       | 3306      | Database port                                                    |
| -d                   | No       | itop      | Database name                                                    |
| -u                   | No       |           | Database user (omit if the defaults file supplies it)            |
| --defaults-file      | No       |           | my.cnf-style credentials file — the recommended path             |
| --password-file      | No       |           | File whose first line is the password                            |
| --mysql-bin          | No       | mysql, then mariadb | Client binary to use                                   |
| --baseline           | No       |           | Known-good count per source, e.g. `'1=39,2=132'`                 |
| --baseline-default   | No       | 0         | Baseline for a source not named in `--baseline`                  |
| --ignore-source      | No       |           | Comma-separated source ids to skip entirely                      |
| -w                   | No       | 1         | How far above baseline triggers WARNING (must be >= 1)           |
| -c                   | No       | *unset*   | Critical threshold above baseline; unset means never CRITICAL    |
| -t / --timeout       | No       | 30        | Query timeout in seconds                                         |
| -V / --version       | No       |           | Show plugin version                                              |
| -h / --help          | No       |           | Show help                                                        |

There is deliberately **no `-p` option** — a password on the command line is
visible in `ps` to every user on the host.

## Behaviour

| Condition                                                        | State    |
|------------------------------------------------------------------|----------|
| Every source at or below its baseline                            | OK       |
| Total excess above baseline at or above `-w`                     | WARNING  |
| Total excess at or above `-c` (only if `-c` is set)              | CRITICAL |
| No replicas found at all                                         | OK       |
| Cannot connect, access denied, unknown table                     | UNKNOWN  |
| Query timed out                                                  | UNKNOWN  |

`-w 0` is rejected: it would alert at the baseline itself, which defeats the
point of having one.

## Baselines

Seed them from the current state, once you are satisfied the current state is
understood:

```
mysql --defaults-file=/etc/icinga2/itop-ro.cnf -h 127.0.0.1 itop -N -B -e \
  "SELECT sync_source_id, SUM(status_last_error <> '') FROM priv_sync_replica GROUP BY sync_source_id;"
```

Then record them in the Icinga configuration — not in a state file on the
agent. A baseline that rewrites itself silently absorbs the next regression.

**When a source drops below its baseline the check says so** in the detail
lines and in the summary (`N baseline(s) now too high`), without alerting. That
is the prompt to lower the recorded value, because a baseline left too high is
a blind spot.

**`--ignore-source` is for sources that are dead by design.** An abandoned data
source whose replicas are permanently in error will otherwise alert forever,
which is the same failure as alerting on non-zero.

## Example Output

```
check_itop_replica_errors OK - 4 replica error(s) across 3 source(s), all at or below baseline | replica_errors_1=3;3;;0 replica_errors_2=1;1;;0 replica_errors_10=0;0;;0 replica_errors_total=4 replica_errors_above_baseline=0;1;;0
[OK] source 1: 3/5 in error, at its baseline of 3
[OK] source 2: 1/4 in error, at its baseline of 1
[OK] source 10: 0/3 in error, at its baseline of 0

check_itop_replica_errors WARNING - 1 replica error(s) above baseline across 3 source(s); worst is source 2 (+1) | ...
[ALERT] source 2: 1/4 in error, 1 above its baseline of 0
```

## Performance Data

| Label                           | Description                                       |
|---------------------------------|---------------------------------------------------|
| `replica_errors_<id>`           | Errors on that source; warn field carries its baseline |
| `replica_errors_total`          | Errors across all non-ignored sources             |
| `replica_errors_above_baseline` | Total excess — the value the thresholds act on    |

## Known Limitations
- `status_last_error` holds only the *most recent* error per replica, so the
  count is of replicas currently in error, not of error events.
- Baselines are maintained by hand. That is deliberate — see above — but it
  does mean they need reviewing when a known fault is genuinely fixed.
- Thresholds act on the **total** excess across sources, not per source; the
  per-source detail lines and perfdata identify which one moved.

## Compatibility Matrix

| Plugin Version | Icinga 2 Version | OS                     | Lang Version |
|----------------|------------------|------------------------|--------------|
| 1.0.0          | >= 2.13.0        | RHEL / Rocky / AlmaLinux 8/9 | Bash 4.x |
| 1.0.0          | >= 2.13.0        | Ubuntu 22.04/24.04     | Bash 5.x     |
| 1.0.0          | >= 2.13.0        | Debian 11/12           | Bash 5.x     |

## License
MIT — see [LICENSE](../../../LICENSE)
