# check_file_age

Checks the age of the **newest** file matching a glob in a directory. Alerts
when that file is too old, when it is implausibly small, or when no such file
exists at all.

This is a check that detects **absence**. A scheduled job that never runs
produces no output, no exit code and no log line, so there is nothing for a
conventional check to notice — "the job did not happen" looks exactly like "the
job has nothing to say". Here, no matching file is a first-class CRITICAL
result, and so is a missing directory.

## Requirements
- Icinga 2 >= 2.13.0
- Bash >= 4.x
- GNU `find` (uses `-printf`) and `timeout` — i.e. `findutils` and `coreutils`
- Read access to the target directory. Backup directories are commonly mode
  `700 root:root`, in which case the check must be run via `sudo` — see
  [INSTALL.md](INSTALL.md).

## Compatibility
See Compatibility Matrix below.

## Usage
```
check_file_age -p <directory> --pattern <glob> [-w <hours>] [-c <hours>]
               [--min-bytes <n>] [-t <seconds>] [-V] [-h]
```

## Arguments

| Argument        | Required | Default | Description                                                    |
|-----------------|----------|---------|----------------------------------------------------------------|
| -p / --path     | Yes      |         | Directory to look in (not recursive)                           |
| --pattern       | Yes      |         | Filename glob, e.g. `itop-db-*.sql.gz`. Must not contain `/`   |
| -w              | No       | 26      | Warning threshold, age of the newest match in hours            |
| -c              | No       | 50      | Critical threshold, age of the newest match in hours           |
| --min-bytes     | No       | 1       | Newest match smaller than this is CRITICAL                     |
| -t / --timeout  | No       | 30      | Timeout in seconds for the directory scan                      |
| -V / --version  | No       |         | Show plugin version                                            |
| -h / --help     | No       |         | Show help                                                      |

## Behaviour

| Condition                                            | State    |
|------------------------------------------------------|----------|
| Newest match is younger than `-w`                    | OK       |
| Newest match is at least `-w` old                    | WARNING  |
| Newest match is at least `-c` old                    | CRITICAL |
| Newest match is smaller than `--min-bytes`           | CRITICAL |
| **No file matches the pattern**                      | CRITICAL |
| **Directory does not exist** (e.g. unmounted volume) | CRITICAL |
| Path exists but is not a directory                   | UNKNOWN  |
| Directory exists but is not readable by this user    | UNKNOWN  |
| Directory scan timed out                             | UNKNOWN  |
| Missing required argument, or `-w` >= `-c`           | UNKNOWN  |

The distinction between the two shaded rows and the UNKNOWN rows is the point of
the check. "There is no backup" is a verdict about the data and must alert;
"I cannot read the directory" is a monitoring permissions problem and must not
be mistaken for one.

A directory whose *name* matches the glob is ignored (`-type f`), because its
mtime would otherwise look reassuringly fresh.

## Why `--min-bytes`

A failed dump often leaves a zero-byte or truncated file behind. That file is
*fresh*, so an age-only check reports OK — the same class of silent false-green
this plugin exists to eliminate. The default of 1 byte only catches a completely
empty file; set it to something realistic for the job being watched.

## Example Output

```
check_file_age OK - itop-db-2026-09-25_2330.sql.gz is 3h old, 7 match(es) | age_seconds=10800s;93600;180000;0 matched_files=7 newest_bytes=418234901B
check_file_age WARNING - itop-db-2026-09-23_2330.sql.gz is 40h old (warning at 26h) | age_seconds=144000s;93600;180000;0 matched_files=7 newest_bytes=418234901B
check_file_age CRITICAL - no file matching 'itop-db-*.sql.gz' in /backups - the job produced nothing | age_seconds=U;93600;180000;0 matched_files=0
```

## Performance Data

| Label           | UOM | Description                                          |
|-----------------|-----|------------------------------------------------------|
| `age_seconds`   | s   | Age of the newest match; `U` when there is no match  |
| `matched_files` |     | Number of files matching the pattern                 |
| `newest_bytes`  | B   | Size of the newest match                             |

Thresholds are emitted in seconds even though `-w`/`-c` are given in hours, so
the graph and the alert agree.

## Known Limitations
- Not recursive: only the named directory is scanned (`-maxdepth 1`).
- Requires GNU `find`; BSD/macOS `find` has no `-printf`.
- Age is taken from mtime, so a job that rewrites an old file will look fresh.
- Thresholds are whole hours. For sub-hour freshness this is the wrong check.

## Compatibility Matrix

| Plugin Version | Icinga 2 Version | OS                     | Lang Version |
|----------------|------------------|------------------------|--------------|
| 1.0.0          | >= 2.13.0        | RHEL / Rocky / AlmaLinux 8/9 | Bash 4.x |
| 1.0.0          | >= 2.13.0        | Ubuntu 22.04/24.04     | Bash 5.x     |
| 1.0.0          | >= 2.13.0        | Debian 11/12           | Bash 5.x     |

## License
MIT — see [LICENSE](../../../LICENSE)
