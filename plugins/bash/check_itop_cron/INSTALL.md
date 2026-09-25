# Installation Guide: check_itop_cron

## Table of Contents
- [Requirements](#requirements)
- [Plugin Installation](#plugin-installation)
- [Database Access](#database-access)
- [Confirm the Schema](#confirm-the-schema)
- [Method 1: Config File Deployment](#method-1-config-file-deployment)
- [Method 2: Icinga Director (UI)](#method-2-icinga-director-ui)
- [Verification](#verification)

## Requirements
- Icinga 2 >= 2.13.0
- Bash >= 4.x
- A `mysql` or `mariadb` client on the node running the check, plus `timeout`
- TCP access to the iTop database, and a read-only database user

## Plugin Installation

```
cp check_itop_cron.sh /usr/lib64/nagios/plugins/check_itop_cron
chmod +x /usr/lib64/nagios/plugins/check_itop_cron
```

> **Plugin path:** these examples use the AlmaLinux 9 path `/usr/lib64/nagios/plugins`
> (the 64-bit RHEL-family `PluginDir`). On Debian/Ubuntu it is `/usr/lib/nagios/plugins`
> — confirm your distribution's `PluginDir` constant and adjust the paths accordingly.

Install it on the node that can reach the database — for a containerised iTop
that is the Docker host — and route the check with `command_endpoint`.

## Database Access

### 1. Make the database reachable over TCP

In a stock containerised iTop deployment the MariaDB service publishes **no
port**: 3306 exists only on the compose network, and every tool reaches it with
`docker exec`. Publish it on loopback so the check does not need Docker
privileges at all:

```yaml
# compose/docker-compose.yml
  mariadb:
    ports:
      - "127.0.0.1:3306:3306"
```

Binding to `127.0.0.1` rather than `0.0.0.0` keeps the database off the network.
Recreate the container for the change to take effect.

### 2. Create a read-only user

Do **not** reuse the application or root credentials. This check needs exactly
one table:

```sql
CREATE USER 'icinga_ro'@'127.0.0.1' IDENTIFIED BY 'choose-a-strong-password';
GRANT SELECT ON itop.priv_async_task TO 'icinga_ro'@'127.0.0.1';
FLUSH PRIVILEGES;
```

### 3. Store the credentials in a defaults file

```
# /etc/icinga2/itop-ro.cnf
[client]
user=icinga_ro
password=choose-a-strong-password
```

```
chown icinga:icinga /etc/icinga2/itop-ro.cnf
chmod 0600 /etc/icinga2/itop-ro.cnf
```

There is no `-p` option on this plugin. A password passed on the command line
appears in `ps` output for every user on the host, and would have to be written
into a CheckCommand in plain text.

## Confirm the Schema

`priv_async_task` stores the scheduled time in `planned` on some iTop versions
and `planned_date` on others. Check before enabling the service:

```
mysql --defaults-file=/etc/icinga2/itop-ro.cnf -h 127.0.0.1 itop \
      -e 'SHOW CREATE TABLE priv_async_task\G' | grep -iE 'planned'
```

If your schema uses `planned_date`, set
`vars.itop_cron_planned_column = "planned_date"`. Getting this wrong is safe but
noisy: the check returns UNKNOWN with `ERROR 1054 Unknown column`, never a false
OK.

## Method 1: Config File Deployment

### CheckCommand Definition

```
cp icinga2/checkcommand.conf /etc/icinga2/conf.d/check_itop_cron_command.conf
```

### Service Template

```
cp icinga2/service_template.conf /etc/icinga2/conf.d/check_itop_cron_service_template.conf
```

Defines `template Service "itop-cron"` — hourly, matching `--stale-hours`.
Polling faster cannot make the check notice a stall any sooner.

### Service Definition

```
cp icinga2/service.conf /etc/icinga2/conf.d/check_itop_cron_service.conf
```

The service reads its database settings from shared `itop_db_*` host variables,
so all three iTop SQL checks are configured once:

```
object Host "helpdesk" {
  import "generic-host"
  address = "10.7.102.60"

  vars.itop                    = true
  vars.itop_db_host            = "127.0.0.1"
  vars.itop_db_port            = 3306
  vars.itop_db_name            = "itop"
  vars.itop_db_defaults_file   = "/etc/icinga2/itop-ro.cnf"
  vars.itop_cron_planned_column = "planned"
}
```

See `servicesets/itop/host_template.conf` for a ready-made host template.

Validate and reload Icinga 2:

```
icinga2 daemon --validate
systemctl reload icinga2
```

## Method 2: Icinga Director (UI)

Assumes Icinga Director is installed and the Kickstart wizard has been
completed. Minimum supported Director version: 1.10.0

### Create CheckCommand

1. Navigate to **Icinga Director > Commands > External Commands**
2. Click **+ Add**
3. Fill in:

   ```
   Name:        check_itop_cron
   Command:     $USER1$/check_itop_cron
   Description: Are iTop background tasks actually being processed?
   ```

4. Switch to the **Arguments** tab and add each argument below. *Type* is the
   Director value type, *Required* mirrors the CheckCommand, *Repeat key*
   (`repeat_key`) applies to array arguments (none here), and *Skip key* is the
   `set_if` boolean that gates a flag argument (none here — every argument
   carries a value):

   | Argument            | Value                        | Type   | Required | Repeat key | Skip key (set_if) | Description                                                   |
   |---------------------|------------------------------|--------|----------|------------|-------------------|---------------------------------------------------------------|
   | `-H`                | `$itop_db_host$`             | String | No       | No         | —                 | Database host (default 127.0.0.1)                             |
   | `-P`                | `$itop_db_port$`             | Number | No       | No         | —                 | Database port (default 3306)                                  |
   | `-d`                | `$itop_db_name$`             | String | No       | No         | —                 | Database name (default itop)                                  |
   | `-u`                | `$itop_db_user$`             | String | No       | No         | —                 | Database user; omit if the defaults file supplies it          |
   | `--defaults-file`   | `$itop_db_defaults_file$`    | String | No       | No         | —                 | my.cnf-style credentials file, mode 0600                      |
   | `--stale-hours`     | `$itop_cron_stale_hours$`    | Number | No       | No         | —                 | How far past due a task must be to count (default 1)          |
   | `--planned-column`  | `$itop_cron_planned_column$` | String | No       | No         | —                 | `planned` or `planned_date`, depending on the iTop version    |
   | `-w`                | `$itop_cron_warning$`        | Number | No       | No         | —                 | Warning threshold, overdue task count (default 1)             |
   | `-c`                | `$itop_cron_critical$`       | Number | No       | No         | —                 | Critical threshold; leave unset to never go CRITICAL          |
   | `-t`                | `$itop_cron_timeout$`        | Number | No       | No         | —                 | Query timeout in seconds (default 30)                         |

5. Click **Store**

Sensitive values: do not put the database password in a Director field. Keep it
in the mode 0600 defaults file on the agent and reference only its path.

### Create Service Template

1. Navigate to **Icinga Director > Services > Service Templates**
2. Click **+ Add**
3. Fill in:

   ```
   Name:               itop-cron
   Check command:      check_itop_cron
   Run on agent:       yes
   Check interval:     1h
   Retry interval:     15m
   Max check attempts: 2
   ```

4. Click **Store**

### Create Service

1. Navigate to **Icinga Director > Services > Apply Rules**
2. Click **+ Add**
3. Fill in:

   ```
   Name:    itop-cron
   Imports: itop-cron
   ```

4. Switch to the **Assign** tab and add: `host.vars.itop` is true
5. Click **Store**, then **Deploy**

To deploy this check alongside the rest of the iTop set, add it to a Director
**Service Set** instead — see `servicesets/itop/README.md`.

Always trigger a **Deploy** after changes in Director.

## Verification

```
/usr/lib64/nagios/plugins/check_itop_cron \
  -H 127.0.0.1 -d itop --defaults-file /etc/icinga2/itop-ro.cnf
```

Expected output on a healthy instance:

```
check_itop_cron OK - no tasks overdue by more than 1h | overdue_tasks=0;1;;0 oldest_overdue_hours=0
```

Run it as the user that will actually execute it, since the defaults file is
mode 0600:

```
sudo -u icinga /usr/lib64/nagios/plugins/check_itop_cron \
  -H 127.0.0.1 -d itop --defaults-file /etc/icinga2/itop-ro.cnf
```

Confirm it fails closed — this is the path most likely to be wrong, and a check
that reports OK when it cannot reach the database is worse than no check:

```
/usr/lib64/nagios/plugins/check_itop_cron -H 127.0.0.1 -P 3399 -d itop \
  --defaults-file /etc/icinga2/itop-ro.cnf
echo $?   # expect 3, with "ERROR 2002 ... Can't connect"
```

Then check the object is live:

```
icinga2 object list --type Service --name "itop-cron"
journalctl -u icinga2 -f
```
