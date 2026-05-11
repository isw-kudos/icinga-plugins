# check_nfs_mount

Verifies that one or more NFS mount points are correctly mounted and accessible.
Uses `/proc/mounts` for mount detection and `stat()`/`listdir()` for responsiveness.
SIGALRM is used per-mount to detect hung/stale mounts that block indefinitely.

## Requirements

- Icinga 2 >= 2.13.0
- Python >= 3.8
- Linux only — requires `/proc/mounts` and SIGALRM (not available on macOS/BSD)
- Plugin must run as a user with read access to all checked mount points
- For write check (`-w`): plugin user must have write permission on the mount

## Compatibility

See Compatibility Matrix below.

## Usage

```
check_nfs_mount -m <path> [-m <path> ...] [-t <timeout>] [-w] [-v] [-V] [-h]
```

## Arguments

| Argument          | Required | Default | Description                                                       |
|-------------------|----------|---------|-------------------------------------------------------------------|
| -m / --mount      | Yes      |         | NFS mount point to check. Repeat for multiple mounts.            |
| -t / --timeout    | No       | 10      | Timeout in seconds per mount (SIGALRM-based)                      |
| -w / --check-write| No       | false   | Verify mount is writable (creates and deletes a pid-scoped file)  |
| -v / --verbose    | No       | false   | Show per-mount detail in output even when all mounts are OK       |
| -V / --version    | No       |         | Show plugin version                                               |
| -h / --help       | No       |         | Show help                                                         |

## Example Output

```
check_nfs_mount OK - All 2 NFS mount(s) OK | '/mnt/data_response_ms'=1.23ms '/mnt/backup_response_ms'=0.87ms
check_nfs_mount CRITICAL - 1/2 NFS mount(s) OK, 1 CRITICAL | '/mnt/data_response_ms'=1.23ms '/mnt/backup_response_ms'=10003.44ms
[CRITICAL] /mnt/backup (NFS 192.168.1.1:/exports/backup) is unresponsive (timeout after 10s) - likely stale mount
check_nfs_mount CRITICAL - 0/1 NFS mount(s) OK, 1 CRITICAL | '/mnt/data_response_ms'=0.00ms
[CRITICAL] /mnt/data is not mounted
```

## Performance Data

| Label                    | UOM | Description                             |
|--------------------------|-----|-----------------------------------------|
| `'<mountpath>_response_ms'` | ms  | Responsiveness time for that mount point |

## How Stale Mount Detection Works

NFS mounts that lose contact with the server enter an uninterruptible sleep
(`D` state) when accessed via `stat()` or `listdir()`. Standard Python threads
and timeouts cannot interrupt this. This plugin uses `signal.alarm()` (SIGALRM)
which IS delivered to the sleeping process, allowing the timeout handler to run
and report the mount as unresponsive.

## Known Limitations

- Linux-only: relies on `/proc/mounts` and `SIGALRM` (POSIX signals)
- SIGALRM cannot be used in multi-threaded Python programs; this plugin is
  intentionally single-threaded
- Write check (`-w`) requires the Icinga agent/user to have write permission;
  not suitable for read-only NFS exports
- The write check creates a file named `.icinga_nfs_check_<pid>` in the mount root

## Compatibility Matrix

| Plugin Version | Icinga 2 Version | OS                     | Lang Version |
|----------------|------------------|------------------------|--------------|
| 1.0.0          | >= 2.13.0        | Ubuntu 22.04/24.04     | Python 3.10  |
| 1.0.0          | >= 2.13.0        | Debian 11/12           | Python 3.9/3.11 |
| 1.0.0          | >= 2.13.0        | RHEL / Rocky Linux 8/9 | Python 3.8/3.9 |

## License

MIT - see [LICENSE](../../../LICENSE)
