# check_isds_replication

Monitors replication health of an IBM Security Directory Server (SDS — formerly
IBM Tivoli Directory Server, now IBM Security Verify Directory) over LDAP. It
enumerates replication agreement entries (`objectclass=ibm-replicationAgreement`)
under a configurable base and inspects each agreement's status attributes.

Per-agreement checks (aggregated to the worst overall state):

| Check            | What it catches                                                                 |
|------------------|---------------------------------------------------------------------------------|
| `state`          | Agreement suspended / on hold / error / retrying — replication not flowing.     |
| `last result`    | A non-zero numeric `ibm-replicationLastResult` (last replication op failed).    |
| `pending changes`| Queued change backlog (`ibm-replicationPendingChangeCount`) crossing `-w`/`-c`. |
| `lag` (optional) | Age of the last replicated change vs `--lag-warn`/`--lag-crit` (disabled by default). |

## Requirements
- Icinga 2 >= 2.13.0
- Bash >= 4.x
- An LDAP search client — both are fully supported and the plugin auto-detects IBM
  vs OpenLDAP flag syntax. The SDS-bundled `idsldapsearch` is auto-located under
  `/opt/*/ldap/*/bin`, so no PATH change is needed when run as the icinga user.
  OpenLDAP `ldapsearch` (`openldap-clients` / `ldap-utils`) also works.
- A bind account allowed to read the replication agreement entries

## Compatibility
See Compatibility Matrix below.

## Usage
```
check_isds_replication -b <base> [-H host] [-p port] [--ldaps|-Z] [-D binddn] \
                       [-y passfile] [--repl-base dn] [--agreement cn]... \
                       [-w pending_warn] [-c pending_crit] \
                       [--lag-warn sec] [--lag-crit sec] [-t timeout] [-V] [-h]
```

## Arguments

| Argument        | Required | Default     | Description                                          |
|-----------------|----------|-------------|------------------------------------------------------|
| -H              | No       | 127.0.0.1   | LDAP host/IP                                         |
| -p              | No       | 389         | LDAP port                                            |
| --ldaps         | No       |             | Use `ldaps://` (set `-p` to the LDAPS port too)      |
| -Z              | No       |             | Use StartTLS on the plain port                       |
| -D              | No       |             | Bind DN (read-only replication monitor account)      |
| -W              | No       |             | Bind password (discouraged — visible in `ps`)        |
| -y              | No       |             | File holding the bind password (preferred)           |
| --ldapsearch-bin| No       | (auto)      | Absolute path to idsldapsearch/ldapsearch (else auto-located on PATH and under /opt/*/ldap/*/bin) |
| --ldap-flavor   | No       | (auto)      | Force `ibm` or `openldap` flag syntax (else auto-detected) |
| --key-file      | No       |             | IBM SSL key database (.kdb) for `--ldaps`            |
| --key-pw        | No       |             | IBM SSL key database password/stash for `--ldaps`    |
| -b / --base     | Yes      |             | Search base for replication agreements               |
| --repl-base     | No       | (from base) | Optional sub-tree under `-b` to search instead        |
| --agreement     | No       | (all)       | Only check the agreement with this cn (repeatable)   |
| -w              | No       | 100         | Warn when pending changes >= N                       |
| -c              | No       | 1000        | Crit when pending changes >= N                       |
| --lag-warn      | No       | (off)       | Warn when last-change age >= seconds                 |
| --lag-crit      | No       | (off)       | Crit when last-change age >= seconds                 |
| -t              | No       | 30          | Timeout in seconds                                   |
| -V              | No       |             | Show version                                         |
| -h              | No       |             | Show help                                            |

## Example Output
```
check_isds_replication OK - replica_b_OK=OK replica_c_OK=OK | agreements_ok=2 agreements_error=0 pending_changes_replica_b=0;100;1000;0; pending_changes_replica_c=3;100;1000;0;
[OK] agreement 'replica-b' state=Ready pending=0 lastResult=0 - healthy
[OK] agreement 'replica-c' state=Ready pending=3 lastResult=0 - healthy
```

Failure example:
```
check_isds_replication CRITICAL - replica_b=CRIT | agreements_ok=0 agreements_error=1 pending_changes_replica_b=5421;100;1000;0;
[CRIT] agreement 'replica-b' state=On Hold pending=5421 lastResult=81 - state 'On Hold'; last result 81 (Server down); 5421 pending changes >= crit 1000
```

## Known Limitations
- Replication agreement attribute names vary across SDS / ISVD versions. If a
  status attribute reports as not found, adjust the names in the *Attribute names*
  block near the top of the script.
- `ibm-replicationChangeLastResultTime` is especially version-dependent. The lag
  sub-check is disabled unless both/either `--lag-warn`/`--lag-crit` are supplied,
  and is silently skipped if the attribute is absent or not a parseable
  generalized time (`YYYYMMDDHHMMSS[.f]Z`).
- If zero agreements are found under the base, the plugin returns `UNKNOWN` (not
  OK) so a mistyped base or missing agreements cannot masquerade as healthy.
- The set of "error" state strings (suspend, on hold, error, retrying, waiting,
  binding) is defined in the `ERROR_STATES` array near the top of the script and
  can be tuned for your SDS version.
- With the IBM `idsldapsearch` client there is no password-file flag, so when you
  pass `-y FILE` the plugin reads the file and supplies the password via `-w`, which
  is briefly visible in the process list (`ps`). The OpenLDAP `ldapsearch` client
  passes the file directly via `-y` and never exposes the password in `ps`. On the
  local SDS host the IBM behaviour is generally acceptable.

## Compatibility Matrix

| Plugin Version | Icinga 2 Version | OS                     | Lang Version |
|----------------|------------------|------------------------|--------------|
| 1.1.0          | >= 2.13.0        | Ubuntu 22.04/24.04     | Bash 5.x     |
| 1.1.0          | >= 2.13.0        | Debian 11/12           | Bash 5.x     |
| 1.1.0          | >= 2.13.0        | RHEL / Rocky Linux 8/9 | Bash 4.x     |

## License
MIT - see LICENSE
