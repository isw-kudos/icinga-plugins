# check_itop_cron

Counts iTop background tasks that are still `planned` well after they were due,
i.e. asks whether `itop-cron` is actually **processing**, not merely running.

The container being up says the process started. This says it is doing its job.
When `itop-cron` stops processing, **notifications stop going out** and there is
no other symptom — tickets still work, the UI is fine, and nobody hears
anything.

## Requirements
- Icinga 2 >= 2.13.0
- Bash >= 4.x
- `mysql` or `mariadb` client, and `timeout`
- TCP access to the iTop database and a read-only user — see
  [INSTALL.md](INSTALL.md)

## Compatibility
See Compatibility Matrix below.

## Usage
```
check_itop_cron [-H <host>] [-P <port>] [-d <database>]
                [--defaults-file <path> | --password-file <path>] [-u <user>]
                [--stale-hours <n>] [--planned-column <name>]
                [-w <n>] [-c <n>] [-t <seconds>] [-V] [-h]
```

## Arguments

| Argument           | Required | Default     | Description                                                     |
|--------------------|----------|-------------|-----------------------------------------------------------------|
| -H                 | No       | 127.0.0.1   | Database host                                                   |
| -P                 | No       | 3306        | Database port                                                   |
| -d                 | No       | itop        | Database name                                                   |
| -u                 | No       |             | Database user (omit if the defaults file supplies it)           |
| --defaults-file    | No       |             | my.cnf-style credentials file — the recommended path            |
| --password-file    | No       |             | File whose first line is the password                           |
| --mysql-bin        | No       | mysql, then mariadb | Client binary to use                                    |
| --stale-hours      | No       | 1           | How far past due a task must be to count                        |
| --planned-column   | No       | planned     | Column holding the scheduled time                               |
| -w                 | No       | 1           | Warning threshold, overdue task count                           |
| -c                 | No       | *unset*     | Critical threshold; unset means the check never goes CRITICAL   |
| -t / --timeout     | No       | 30          | Query timeout in seconds                                        |
| -V / --version     | No       |             | Show plugin version                                             |
| -h / --help        | No       |             | Show help                                                       |

There is deliberately **no `-p` option**. A password on the command line is
visible in `ps` to every user on the host, and would end up written into a
CheckCommand. Use `--defaults-file`.

## Behaviour

| Condition                                              | State    |
|--------------------------------------------------------|----------|
| No task overdue by more than `--stale-hours`           | OK       |
| Overdue count at or above `-w`                         | WARNING  |
| Overdue count at or above `-c` (only if `-c` is set)   | CRITICAL |
| Cannot connect, access denied, or unknown column/table | UNKNOWN  |
| Query timed out                                        | UNKNOWN  |
| Query returned no rows at all                          | UNKNOWN  |

Every database failure is UNKNOWN, never OK. A check that cannot reach the
database must not report that everything is fine.

## The column name is version-dependent

`priv_async_task` stores the scheduled time in `planned` on some iTop versions
and `planned_date` on others. The default here is `planned`, which is the form
verified against this estate's own runbook. Confirm before enabling:

```
SHOW CREATE TABLE itop.priv_async_task;
```

and set `--planned-column planned_date` if that is what your schema uses. A
wrong column name produces `ERROR 1054 Unknown column` and an UNKNOWN result —
it fails loudly rather than silently reporting OK.

## Known Limitations
- **Detection lags a stall by `--stale-hours`.** Zero overdue tasks is equally
  true when cron is healthy and when cron is dead with an empty queue, so a
  stall only becomes visible once work has piled up past the horizon. This is
  inherent to counting a backlog rather than reading a last-run timestamp.
- Tasks with a `NULL` scheduled time are not counted; their age is unknowable.
- `NOW()` is evaluated by the database, so the plugin host's clock is
  irrelevant — but the column's stored timezone should be confirmed rather than
  assumed.

## Example Output

```
check_itop_cron OK - no tasks overdue by more than 1h | overdue_tasks=0;1;;0 oldest_overdue_hours=0
check_itop_cron WARNING - 3 task(s) still planned more than 1h past due (oldest 26h) - itop-cron is not processing | overdue_tasks=3;1;;0 oldest_overdue_hours=26
check_itop_cron UNKNOWN - mariadb failed (rc=1): ERROR 1045 (28000): Access denied for user 'icinga_ro'@'localhost'
```

## Performance Data

| Label                  | Description                                        |
|------------------------|----------------------------------------------------|
| `overdue_tasks`        | Tasks still planned past the horizon               |
| `oldest_overdue_hours` | Age of the oldest such task, 0 when there are none |

## Compatibility Matrix

| Plugin Version | Icinga 2 Version | OS                     | Lang Version |
|----------------|------------------|------------------------|--------------|
| 1.0.0          | >= 2.13.0        | RHEL / Rocky / AlmaLinux 8/9 | Bash 4.x |
| 1.0.0          | >= 2.13.0        | Ubuntu 22.04/24.04     | Bash 5.x     |
| 1.0.0          | >= 2.13.0        | Debian 11/12           | Bash 5.x     |

## License
MIT — see [LICENSE](../../../LICENSE)
