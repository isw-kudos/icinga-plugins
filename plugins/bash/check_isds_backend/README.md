# check_isds_backend

Monitors the **host-local backend health** of an IBM Security Directory Server
(SDS — formerly IBM Tivoli Directory Server, now IBM Security Verify Directory):
the SDS/DB2 processes and the DB2 storage backend. Designed to run **locally on
the SDS host** (via the Icinga agent), complementing
[`check_isds_monitor`](../check_isds_monitor/README.md), which reads `cn=monitor`
over LDAP. Together they cover both the LDAP-visible health and the on-box health
that LDAP cannot see.

Three sub-checks (all enabled by default, individually toggleable):

| Sub-check        | What it catches                                                                 |
|------------------|---------------------------------------------------------------------------------|
| `proc`           | SDS/DB2 processes down. `ibmslapd` (LDAP server) and `db2sysc` (DB2 engine) are CRITICAL if missing; `ibmdiradm` (admin daemon) is WARNING by default (CRITICAL with `--diradm-crit`). |
| `db2-tablespace` | DB2 tablespace utilization climbing toward full. WARN/CRIT if any tablespace exceeds the percent threshold. |
| `db2-logs`       | DB2 transaction-log utilization — a full log halts all writes.                  |

## Requirements
- Icinga 2 >= 2.13.0
- Bash >= 4.x
- Runs locally on the SDS host
- `pgrep` (procps) for the `proc` sub-check
- The DB2 CLI (`db2`) for the `db2-*` sub-checks. Because DB2 commands must run as
  the instance owner, either run the plugin as that user or pass `--db2-user`
  (which wraps calls in `su - <user> -c ...`; the Icinga user then needs sudo —
  see INSTALL.md).

## Compatibility
See Compatibility Matrix below.

## Usage
```
check_isds_backend [--db2-instance NAME] [--db2-database DB] [--db2-user USER] \
                   [-w PCT] [-c PCT] [--log-warn PCT] [--log-crit PCT] \
                   [--diradm-crit] [--no-diradm] \
                   [--check proc|db2-tablespace|db2-logs] \
                   [--no-proc|--no-db2-tablespace|--no-db2-logs] \
                   [-t timeout] [-V] [-h]
```

## Arguments

| Argument            | Required        | Default     | Description                                          |
|---------------------|-----------------|-------------|------------------------------------------------------|
| --db2-instance      | For `db2-*`     |             | DB2 instance name (e.g. `dsrdbm01`)                  |
| --db2-database      | For `db2-*`     |             | DB2 database name (e.g. `ldapdb2`)                   |
| --db2-user          | No              |             | Run db2 as this OS user via `su - USER -c ...`       |
| -w                  | No              | 85          | Tablespace warn threshold (%)                        |
| -c                  | No              | 95          | Tablespace crit threshold (%)                        |
| --log-warn          | No              | 80          | Transaction-log warn threshold (%)                   |
| --log-crit          | No              | 90          | Transaction-log crit threshold (%)                   |
| --diradm-crit       | No              |             | Treat a missing `ibmdiradm` as CRITICAL (vs WARNING) |
| --no-diradm         | No              |             | Skip the `ibmdiradm` process check                   |
| --check             | No              | (all)       | Run only this sub-check; repeatable (allowlist mode) |
| --no-proc           | No              |             | Disable the process liveness sub-check               |
| --no-db2-tablespace | No              |             | Disable the DB2 tablespace sub-check                 |
| --no-db2-logs       | No              |             | Disable the DB2 transaction-log sub-check            |
| -t                  | No              | 30          | Timeout per external command (seconds)               |
| -V                  | No              |             | Show version                                         |
| -h                  | No              |             | Show help                                            |

### Selecting sub-checks
Two consistent mechanisms, mirroring the rest of the suite:
- `--no-<name>` disables a single sub-check (all others still run).
- `--check <name>` switches to **allowlist** mode: the first `--check` disables
  everything, then each `--check <name>` re-enables one. Repeat to select a
  subset, e.g. `--check db2-tablespace --check db2-logs`.

If neither is given, all three sub-checks run.

## Example Output
```
check_isds_backend OK - proc_ibmslapd=OK proc_db2=OK proc_ibmdiradm=OK db2_tablespace=OK db2_logs=OK | procs_ibmslapd=1 procs_db2=4 procs_ibmdiradm=1 tablespace_used_pct_userspace1=62%;85;95;0;100 tablespace_used_pct_ldapspace=71%;85;95;0;100 log_used_pct=18%;80;90;0;100
[OK] ibmslapd running (1)
[OK] db2sysc running (4)
[OK] ibmdiradm running (1)
[OK] all tablespaces below 85%
[OK] transaction log 18% used
```

## Known Limitations
- **Process names** are matched with `pgrep -f` against the patterns in the
  *Process patterns* block near the top of the script (`ibmslapd`, `ibmdiradm`,
  `db2sysc`). Confirm these against the actual process names on your host and
  adjust if needed — DB2 may also show per-EDU `db2sysc` threads.
- **DB2 SQL / parsing** differs across DB2 versions. The tablespace query
  (`SYSIBMADM.TBSP_UTILIZATION`) and log query (`MON_GET_TRANSACTION_LOG`) live in
  clearly marked *DB2 QUERY* blocks in the script. If a sub-check returns
  `UNKNOWN`, adjust the SQL there (e.g. fall back to `db2pd -db <db> -logs`).
- DB2 commands must run as the instance owner; without `--db2-user` the plugin
  must itself run as that user.
- Tablespace/log percentages are point-in-time; pair with Icinga graphing of the
  emitted perfdata to spot trends.

## Compatibility Matrix

| Plugin Version | Icinga 2 Version | OS                     | Lang Version |
|----------------|------------------|------------------------|--------------|
| 1.0.0          | >= 2.13.0        | Ubuntu 22.04/24.04     | Bash 5.x     |
| 1.0.0          | >= 2.13.0        | Debian 11/12           | Bash 5.x     |
| 1.0.0          | >= 2.13.0        | RHEL / Rocky Linux 8/9 | Bash 4.x     |

## License
MIT - see LICENSE
