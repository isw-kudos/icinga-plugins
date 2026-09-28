# check_itop_mail

Checks that iTop's mail is **actually leaving**, and is not being swallowed by a
local capture sink.

Two independent assertions, deliberately at different severities:

1. **Configuration (CRITICAL).** The transport still sends mail off the host,
   and the relay is not a capture sink. A migration commonly leaves the instance
   pointed at a mail catcher; every notification then disappears in complete
   silence, with no error anywhere and nothing in any log.
2. **Database (WARNING).** No send failures were recorded in the last window.

## The direction of the assertion matters

A deploy-time script asserts the opposite of this one: during a migration, mail
**must** be trapped. In production that inverts — mail must be able to leave.
Running the deploy-time direction against a live instance is exactly how a check
ends up crying wolf on the expected state, and a check that does that gets
ignored. This plugin asserts the production direction.

## Requirements
- Icinga 2 >= 2.13.0
- Bash >= 4.x, `awk`, `timeout`
- `mysql` or `mariadb` client (only when the database half is enabled)
- Read access to `config-itop.php`, which is typically mode `440` owned by the
  web user — see [INSTALL.md](INSTALL.md)

No PHP is required. The configuration is parsed directly, because on a
containerised deployment the interpreter lives inside the application container
and not on the Docker host.

## Compatibility
See Compatibility Matrix below.

## Usage
```
check_itop_mail [--config <path>] [--expect-transport <name>]
                [--forbid-host <host>]... [--expect-verify-peer <0|1>]
                [-H <host>] [-P <port>] [-d <database>]
                [--defaults-file <path> | --password-file <path>] [-u <user>]
                [--window-hours <n>] [--failure-prefix <text>]
                [--no-config] [--no-db] [-w <n>] [-c <n>] [-t <seconds>] [-V] [-h]
```

## Arguments

| Argument               | Required | Default                | Description                                                        |
|------------------------|----------|------------------------|--------------------------------------------------------------------|
| --config               | Yes*     |                        | Path to `config-itop.php` (*unless `--no-config`)                  |
| --expect-transport     | No       | SMTP                   | Transport that means mail leaves the host                          |
| --forbid-host          | No       |                        | Relay hostname that is a capture sink. **Repeatable**              |
| --expect-verify-peer   | No       | *unset*                | Assert `verify_peer` is 0 or 1; omit to skip                       |
| --no-config            | No       | off                    | Skip the configuration half                                        |
| --no-db                | No       | off                    | Skip the database half                                             |
| -H                     | No       | 127.0.0.1              | Database host                                                      |
| -P                     | No       | 3306                   | Database port                                                      |
| -d                     | No       | itop                   | Database name                                                      |
| -u                     | No       |                        | Database user                                                      |
| --defaults-file        | No       |                        | my.cnf-style credentials file — the recommended path               |
| --password-file        | No       |                        | File whose first line is the password                              |
| --window-hours         | No       | 1                      | How far back to look for send failures                             |
| --failure-prefix       | No       | `Sending eMail failed` | `priv_event.message` prefix marking a real failure                 |
| -w                     | No       | 1                      | Warning threshold, failure count                                   |
| -c                     | No       | *unset*                | Critical threshold; unset means the send half never goes CRITICAL  |
| -t / --timeout         | No       | 30                     | Query timeout in seconds                                           |
| -V / --version         | No       |                        | Show plugin version                                                |
| -h / --help            | No       |                        | Show help                                                          |

There is deliberately **no `-p` option** — a password on the command line is
visible in `ps` to every user on the host.

## Behaviour

| Condition                                                          | State    |
|--------------------------------------------------------------------|----------|
| Transport is as expected, relay is not a sink, no failures         | OK       |
| **Transport is not `--expect-transport`** (LogFile, Null)          | CRITICAL |
| **Relay matches a `--forbid-host`**                                | CRITICAL |
| `verify_peer` absent or not as asserted (only with `--expect-verify-peer`) | WARNING |
| Send failures at or above `-w`                                     | WARNING  |
| Send failures at or above `-c` (only if `-c` is set)               | CRITICAL |
| Config file missing, unreadable, or `email_transport` unset        | UNKNOWN  |
| Database unreachable, access denied, or query timed out            | UNKNOWN  |
| Both halves disabled                                               | UNKNOWN  |

Severity is ordered **CRITICAL > WARNING > UNKNOWN**, not the repo's usual
ladder. This is load-bearing: an unreachable database must not mask a
configuration pointing at a sink. The test suite asserts that case directly.

## Which config keys are read

| Key                                 | Used for                                          |
|-------------------------------------|---------------------------------------------------|
| `email_transport`                   | Must equal `--expect-transport`                   |
| `email_transport_smtp.host`         | Must not match any `--forbid-host` (case-insensitive) |
| `email_transport_smtp.verify_peer`  | Only with `--expect-verify-peer`                  |

Note the key is `email_transport_smtp.host`, **not** `smtp_host` — the latter is
not an iTop setting.

An **absent** `verify_peer` is called out separately from a wrong one, because
it is worse: the STARTTLS handshake fails and no mail goes out at all.

## Example Output

```
check_itop_mail OK - config=OK sends=OK | mail_sink=0 email_failures=0;1;;0
[OK] transport SMTP, relay 'smtp.ams.cloud' is not a sink
[OK] no send failures in the last 1h

check_itop_mail CRITICAL - config=CRIT sends=OK | mail_sink=1 email_failures=0;1;;0
[CRIT] relay is 'mailpit', a configured capture sink - every notification is being swallowed

check_itop_mail CRITICAL - config=CRIT sends=UNKNOWN | mail_sink=1 email_failures=U;1;;0
[CRIT] email_transport is 'LogFile', expected 'SMTP' - notifications are not leaving this host
[UNKNOWN] mariadb failed (rc=1): ERROR 2002 (HY000): Can't connect to server
```

## Performance Data

| Label            | Description                                              |
|------------------|----------------------------------------------------------|
| `mail_sink`      | 1 when mail cannot leave, 0 when it can, `U` not checked |
| `email_failures` | Send failures in the window, `U` when not checked        |

## Known Limitations
- The config is parsed textually. A value built by PHP expression rather than
  written as a literal will not be read; iTop writes plain scalars.
- `priv_event.message` is free text, so the failure test is a prefix match.
  `--failure-prefix` exists for instances whose wording differs.
- `No recipient` is deliberately **not** counted — it means a trigger resolved
  to nobody, which is normal, not a delivery failure.
- The check confirms mail *can* leave and that none failed; it cannot confirm
  anything was delivered.

## Compatibility Matrix

| Plugin Version | Icinga 2 Version | OS                     | Lang Version |
|----------------|------------------|------------------------|--------------|
| 1.0.0          | >= 2.13.0        | RHEL / Rocky / AlmaLinux 8/9 | Bash 4.x |
| 1.0.0          | >= 2.13.0        | Ubuntu 22.04/24.04     | Bash 5.x     |
| 1.0.0          | >= 2.13.0        | Debian 11/12           | Bash 5.x     |

## License
MIT — see [LICENSE](../../../LICENSE)
