# Installation Guide: check_itop_replica_errors

## Table of Contents
- [Requirements](#requirements)
- [Plugin Installation](#plugin-installation)
- [Database Access](#database-access)
- [Establishing the Baselines](#establishing-the-baselines)
- [Method 1: Config File Deployment](#method-1-config-file-deployment)
- [Method 2: Icinga Director (UI)](#method-2-icinga-director-ui)
- [Verification](#verification)

## Requirements
- Icinga 2 >= 2.13.0
- Bash >= 4.x (the plugin uses associative arrays)
- A `mysql` or `mariadb` client on the node running the check, plus `timeout`
- TCP access to the iTop database, and a read-only database user

## Plugin Installation

```
cp check_itop_replica_errors.sh /usr/lib64/nagios/plugins/check_itop_replica_errors
chmod +x /usr/lib64/nagios/plugins/check_itop_replica_errors
```

> **Plugin path:** these examples use the AlmaLinux 9 path `/usr/lib64/nagios/plugins`
> (the 64-bit RHEL-family `PluginDir`). On Debian/Ubuntu it is `/usr/lib/nagios/plugins`
> — confirm your distribution's `PluginDir` constant and adjust the paths accordingly.

## Database Access

### 1. Make the database reachable over TCP

In a stock containerised iTop deployment MariaDB publishes **no port** — 3306
exists only on the compose network. Publish it on loopback:

```yaml
# compose/docker-compose.yml
  mariadb:
    ports:
      - "127.0.0.1:3306:3306"
```

Binding to `127.0.0.1` keeps the database off the network. Recreate the
container for the change to take effect.

### 2. Create a read-only user

```sql
CREATE USER 'icinga_ro'@'%' IDENTIFIED BY 'choose-a-strong-password';
GRANT SELECT ON itop.priv_sync_replica TO 'icinga_ro'@'%';
FLUSH PRIVILEGES;
```

> **Grant to `@'%'`, not `@'127.0.0.1'`.** When the database port is published
> from a container, the connection reaches MariaDB from the Docker bridge
> gateway (e.g. `172.18.0.1`), not from loopback — a `@'127.0.0.1'` user is
> rejected with *Access denied for user 'icinga_ro'@'172.18.0.1'*. Binding the
> published port to `127.0.0.1` is what restricts access to host-local
> processes; the grant host cannot do it. Scope it to the bridge subnet instead
> if you prefer, but that subnet changes when the compose network is recreated.

If you are deploying the other iTop checks too, grant `priv_async_task` and
`priv_event` to the same user.

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

## Establishing the Baselines

This is the step that decides whether the check is useful or noise. Read the
current state first:

```
mysql --defaults-file=/etc/icinga2/itop-ro.cnf -h 127.0.0.1 itop -N -B -e \
  "SELECT sync_source_id, SUM(status_last_error <> ''), COUNT(*) \
     FROM priv_sync_replica GROUP BY sync_source_id ORDER BY sync_source_id;"
```

Then, for each source, decide which of three things it is:

1. **A fault you understand and have accepted** — record the count as its
   baseline, e.g. `--baseline '1=39,2=132'`. The check then only alerts when it
   gets *worse*.
2. **A source that is dead by design** — an abandoned collector whose replicas
   are permanently in error. Put it in `--ignore-source`. Leaving it in would
   alert forever, which is the same failure as alerting on non-zero.
3. **Genuinely clean** — leave it out; `--baseline-default 0` covers it.

Record the baselines in the Icinga configuration, not in a file on the agent,
so that "what normal looks like" is reviewable in version control rather than a
number that quietly rewrites itself.

Re-read the query and lower a baseline whenever the check reports
`N baseline(s) now too high` — a baseline left above reality is a blind spot.

## Method 1: Config File Deployment

### CheckCommand Definition

```
cp icinga2/checkcommand.conf /etc/icinga2/conf.d/check_itop_replica_errors_command.conf
```

### Service Template

```
cp icinga2/service_template.conf /etc/icinga2/conf.d/check_itop_replica_errors_service_template.conf
```

Defines `template Service "itop-replica-errors"` — hourly. This is the
**level-based** counterpart to an edge-triggered sync-health cron job: it
reports the current count on every poll, so the alert persists for as long as
the fault does, rather than firing once on the change and clearing while the
problem is still there.

### Service Definition

```
cp icinga2/service.conf /etc/icinga2/conf.d/check_itop_replica_errors_service.conf
```

```
object Host "helpdesk" {
  import "generic-host"
  address = "10.7.102.60"

  vars.itop                  = true
  vars.itop_db_host          = "127.0.0.1"
  vars.itop_db_name          = "itop"
  vars.itop_db_defaults_file = "/etc/icinga2/itop-ro.cnf"

  vars.itop_replica_errors_baseline       = "1=39,2=132"
  vars.itop_replica_errors_ignore_sources = "5,6,15,16"
}
```

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
   Name:        check_itop_replica_errors
   Command:     $USER1$/check_itop_replica_errors
   Description: iTop synchro replicas in error, per source, against a baseline
   ```

4. Switch to the **Arguments** tab and add each argument below. *Type* is the
   Director value type, *Required* mirrors the CheckCommand, *Repeat key*
   (`repeat_key`) applies to array arguments (none here — the baseline is a
   single comma-separated string), and *Skip key* is the `set_if` boolean that
   gates a flag argument (none here — every argument carries a value):

   | Argument              | Value                                           | Type   | Required | Repeat key | Skip key (set_if) | Description                                                    |
   |-----------------------|-------------------------------------------------|--------|----------|------------|-------------------|----------------------------------------------------------------|
   | `-H`                  | `$itop_db_host$`                                | String | No       | No         | —                 | Database host (default 127.0.0.1)                              |
   | `-P`                  | `$itop_db_port$`                                | Number | No       | No         | —                 | Database port (default 3306)                                   |
   | `-d`                  | `$itop_db_name$`                                | String | No       | No         | —                 | Database name (default itop)                                   |
   | `-u`                  | `$itop_db_user$`                                | String | No       | No         | —                 | Database user; omit if the defaults file supplies it           |
   | `--defaults-file`     | `$itop_db_defaults_file$`                       | String | No       | No         | —                 | my.cnf-style credentials file, mode 0600                       |
   | `--baseline`          | `$itop_replica_errors_baseline$`                | String | No       | No         | —                 | Known-good count per source, e.g. `1=39,2=132`                 |
   | `--baseline-default`  | `$itop_replica_errors_baseline_default$`        | Number | No       | No         | —                 | Baseline for sources not named above (default 0)               |
   | `--ignore-source`     | `$itop_replica_errors_ignore_sources$`          | String | No       | No         | —                 | Comma-separated source ids that are dead by design             |
   | `-w`                  | `$itop_replica_errors_warning$`                 | Number | No       | No         | —                 | How far above baseline triggers WARNING (default 1)            |
   | `-c`                  | `$itop_replica_errors_critical$`                | Number | No       | No         | —                 | Critical threshold above baseline; unset = never CRITICAL      |
   | `-t`                  | `$itop_db_timeout$`                             | Number | No       | No         | —                 | Query timeout in seconds (default 30)                          |

5. Click **Store**

Sensitive values: keep the database password in the mode 0600 defaults file on
the agent and reference only its path. Do not store it as a Director property.

### Create Service Template

1. Navigate to **Icinga Director > Services > Service Templates**
2. Click **+ Add**
3. Fill in:

   ```
   Name:               itop-replica-errors
   Check command:      check_itop_replica_errors
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
   Name:    itop-replica-errors
   Imports: itop-replica-errors
   ```

4. Switch to the **Custom Properties** tab and set
   `itop_replica_errors_baseline` and `itop_replica_errors_ignore_sources`
5. Switch to the **Assign** tab and add: `host.vars.itop` is true
6. Click **Store**, then **Deploy**

To deploy this alongside the rest of the iTop checks, add it to a Director
**Service Set** instead — see `servicesets/itop/README.md`.

## Verification

```
/usr/lib64/nagios/plugins/check_itop_replica_errors \
  -H 127.0.0.1 -d itop --defaults-file /etc/icinga2/itop-ro.cnf \
  --baseline '1=39,2=132' --ignore-source '5,6,15,16'
```

Expected output:

```
check_itop_replica_errors OK - 171 replica error(s) across 6 source(s), all at or below baseline | replica_errors_1=39;39;;0 ...
```

Run it as the user that will execute it, since the defaults file is mode 0600:

```
sudo -u icinga /usr/lib64/nagios/plugins/check_itop_replica_errors \
  -H 127.0.0.1 -d itop --defaults-file /etc/icinga2/itop-ro.cnf
```

**Confirm the check can actually fire.** This matters more here than for most
checks: the query this replaces (`WHERE status = 'error'`) returns zero rows on
every iTop schema, and a check that can never fire is indistinguishable from a
healthy one. Run it once with no baselines and confirm it reports the real
counts:

```
/usr/lib64/nagios/plugins/check_itop_replica_errors \
  -H 127.0.0.1 -d itop --defaults-file /etc/icinga2/itop-ro.cnf
echo $?   # expect 1 (WARNING) on any estate that has replica errors at all
```

If that reports OK with `replica_errors_total=0`, verify by hand before
believing it:

```
mysql --defaults-file=/etc/icinga2/itop-ro.cnf -h 127.0.0.1 itop -N -B -e \
  "SELECT SUM(status_last_error <> '') FROM priv_sync_replica;"
```

Then check the object is live:

```
icinga2 object list --type Service --name "itop-replica-errors"
journalctl -u icinga2 -f
```
