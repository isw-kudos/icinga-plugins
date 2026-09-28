# iTop Service Set

Seven application-level checks for an iTop instance, deployable as one unit.

Host-level monitoring — CPU, memory, disk, systemd units, SSH, ping, the public
certificate — tells you the box is healthy. It does not tell you the service
works. An iTop instance can be unreachable through the load balancer, running
without a backup for years, silently swallowing every notification, or holding
synchro work that was started and never finished, while every host check stays
green throughout.

## What is in the set

| # | Service | Check | Severity | Interval |
|---|---------|-------|----------|----------|
| 1 | `itop-http` | ITL `http` (reused) | CRITICAL | 1m |
| 2 | `itop-backup-age` | `check_file_age` | WARN 26h / CRIT 50h | 1h |
| 3 | `itop-backup-integrity` | `check_archive_integrity` | CRITICAL | 24h |
| 5 | `itop-replica-errors` | `check_itop_replica_errors` | WARNING | 1h |
| 7 | `itop-containers`, `itop-containers-health`, `itop-cron-container` | `check_docker` (reused) | CRITICAL | 2m |
| 8 | `itop-cron` | `check_itop_cron` | WARNING | 1h |
| 9 | `itop-mail` | `check_itop_mail` | CRIT / WARN | 1h |

Nine services for seven checks: the container check is split three ways, for
reasons given below.

**Two of the seven add no new code.** Check 1 uses the ITL `http` command
(`nagios-plugins-http` is already installed on agents), and check 7 uses
`check_docker.py`, which is already deployed to `PluginDir`. Writing plugins to
duplicate either would have added maintenance for nothing.

> Deploy **either** this set **or** the per-plugin `service.conf` files — not
> both. They define apply rules of the same names, and Icinga refuses to start
> on a duplicate object.

## Prerequisites

### 1. Install the five plugins

```
for p in check_file_age check_archive_integrity check_itop_cron \
         check_itop_replica_errors check_itop_mail; do
  cp "plugins/bash/$p/$p.sh" "/usr/lib64/nagios/plugins/$p"
  chmod +x "/usr/lib64/nagios/plugins/$p"
done
```

> **Plugin path:** these examples use the AlmaLinux 9 path `/usr/lib64/nagios/plugins`.
> On Debian/Ubuntu it is `/usr/lib/nagios/plugins` — confirm your distribution's
> `PluginDir` constant and adjust every path below, including the sudoers rules.

Install them on the **iTop host**, not the master. All of them except
`itop-http` run with `command_endpoint = host.name`.

### 2. Publish MariaDB on loopback

In a stock containerised iTop deployment the database publishes **no port** —
3306 exists only on the compose network, and every tool reaches it through
`docker exec`. The three SQL checks connect over TCP, so publish it:

```yaml
# compose/docker-compose.yml
  mariadb:
    ports:
      - "127.0.0.1:3306:3306"
```

Binding to `127.0.0.1` rather than `0.0.0.0` keeps the database off the network.
Recreate the container for the change to take effect.

### 3. Create a read-only database user

Not the application user, and not root:

```sql
CREATE USER 'icinga_ro'@'127.0.0.1' IDENTIFIED BY 'choose-a-strong-password';
GRANT SELECT ON itop.priv_sync_replica TO 'icinga_ro'@'127.0.0.1';
GRANT SELECT ON itop.priv_async_task   TO 'icinga_ro'@'127.0.0.1';
GRANT SELECT ON itop.priv_event        TO 'icinga_ro'@'127.0.0.1';
FLUSH PRIVILEGES;
```

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

None of the plugins accept a password on the command line. A command-line
password is visible in `ps` to every user on the host and would have to be
stored in plain text in a CheckCommand.

### 4. Sudoers for the file-reading checks

`/backups` is typically mode `700 root:root` with dumps mode `600`, and
`config-itop.php` is mode `440` owned by the web user. The `icinga` user can
read none of them. Grant exactly three commands, by exact path:

```
# /etc/sudoers.d/icinga-itop
icinga ALL = (root) NOPASSWD: /usr/lib64/nagios/plugins/check_file_age
icinga ALL = (root) NOPASSWD: /usr/lib64/nagios/plugins/check_archive_integrity
icinga ALL = (root) NOPASSWD: /usr/lib64/nagios/plugins/check_itop_mail
```

```
chmod 0440 /etc/sudoers.d/icinga-itop
visudo -c
```

Then prefix those three commands with `sudo` in their CheckCommands, e.g.
`command = [ "sudo", PluginDir + "/check_file_age" ]`.

Do not widen the permissions on the backups or the config instead — the config
holds the application's database password and encryption key.

### 5. Container access

`check_docker` needs to reach the Docker socket. In this estate the `icinga`
user is already in the `docker` group. Be aware that docker group membership is
equivalent to root on the host; if you would rather not grant it for a status
check, use a narrow sudoers entry for `check_docker` instead.

## Method 1: Config File Deployment

```
cp plugins/bash/check_file_age/icinga2/checkcommand.conf            /etc/icinga2/conf.d/itop-01-cmd-file-age.conf
cp plugins/bash/check_archive_integrity/icinga2/checkcommand.conf   /etc/icinga2/conf.d/itop-02-cmd-archive-integrity.conf
cp plugins/bash/check_itop_cron/icinga2/checkcommand.conf           /etc/icinga2/conf.d/itop-03-cmd-cron.conf
cp plugins/bash/check_itop_replica_errors/icinga2/checkcommand.conf /etc/icinga2/conf.d/itop-04-cmd-replica-errors.conf
cp plugins/bash/check_itop_mail/icinga2/checkcommand.conf           /etc/icinga2/conf.d/itop-05-cmd-mail.conf
cp servicesets/itop/checkcommand_docker.conf                        /etc/icinga2/conf.d/itop-06-cmd-docker.conf

cp plugins/bash/check_file_age/icinga2/service_template.conf            /etc/icinga2/conf.d/itop-10-tpl-file-age.conf
cp plugins/bash/check_archive_integrity/icinga2/service_template.conf   /etc/icinga2/conf.d/itop-11-tpl-archive-integrity.conf
cp plugins/bash/check_itop_cron/icinga2/service_template.conf           /etc/icinga2/conf.d/itop-12-tpl-cron.conf
cp plugins/bash/check_itop_replica_errors/icinga2/service_template.conf /etc/icinga2/conf.d/itop-13-tpl-replica-errors.conf
cp plugins/bash/check_itop_mail/icinga2/service_template.conf           /etc/icinga2/conf.d/itop-14-tpl-mail.conf

cp servicesets/itop/host_template.conf /etc/icinga2/conf.d/itop-20-host-template.conf
cp servicesets/itop/services.conf      /etc/icinga2/conf.d/itop-21-services.conf
```

Omit `itop-06-cmd-docker.conf` if your master already defines a `check_docker`
command.

Then import the host template and override what differs:

```
object Host "helpdesk" {
  import "generic-host"
  import "itop-host"

  address = "10.7.102.60"

  vars.itop_http_vhost  = "support.collab.cloud"
  vars.itop_mail_config = "/data/itop_migration/conf/production/config-itop.php"

  vars.itop_replica_errors_baseline       = "1=39,2=132"
  vars.itop_replica_errors_ignore_sources = "5,6,15,16"
}
```

```
icinga2 daemon --validate
systemctl reload icinga2
icinga2 object list --type Service --name "itop-*"
```

## Method 2: Icinga Director (UI)

Minimum supported Director version: 1.10.0

### 1. Create the CheckCommands

Follow the **Method 2 > Create CheckCommand** section in each plugin's
`INSTALL.md`, which gives the full Arguments table for that command:

- [check_file_age](../../plugins/bash/check_file_age/INSTALL.md)
- [check_archive_integrity](../../plugins/bash/check_archive_integrity/INSTALL.md)
- [check_itop_cron](../../plugins/bash/check_itop_cron/INSTALL.md)
- [check_itop_replica_errors](../../plugins/bash/check_itop_replica_errors/INSTALL.md)
- [check_itop_mail](../../plugins/bash/check_itop_mail/INSTALL.md)

For `check_docker`, add an External Command named `check_docker` with command
`$USER1$/check_docker` and these arguments:

| Argument       | Value                          | Type    | Required | Repeat key | Skip key (set_if)          | Description                                                  |
|----------------|--------------------------------|---------|----------|------------|----------------------------|--------------------------------------------------------------|
| `--containers` | `$check_docker_containers$`    | Array   | Yes      | **No**     | —                          | Anchored name regexes, e.g. `^itop$`                         |
| `--present`    | (none)                         | Boolean | No       | No         | `$check_docker_present$`   | Each regex must match at least one container                 |
| `--status`     | `$check_docker_status$`        | String  | No       | No         | —                          | Desired status, e.g. `running`                               |
| `--health`     | (none)                         | Boolean | No       | No         | `$check_docker_health$`    | Check the healthcheck; UNKNOWN if the container has none     |
| `--uptime`     | `$check_docker_uptime$`        | String  | No       | No         | —                          | Minimum uptime seconds as `WARN:CRIT`                        |
| `--restarts`   | `$check_docker_restarts$`      | String  | No       | No         | —                          | Restart count thresholds as `WARN:CRIT`                      |
| `--timeout`    | `$check_docker_timeout$`       | Number  | No       | No         | —                          | Timeout in seconds                                           |

**Repeat key must be No on `--containers`.** The plugin declares that option
with `nargs='+'`, so it expects `--containers '^a$' '^b$'`. Director's default
is to repeat the key, which would produce `--containers a --containers b` — and
argparse keeps only the last, silently monitoring one container while appearing
to monitor several.

### 2. Create the Service Templates

**Services > Service Templates > + Add**, one per check, each with *Run on
agent* set to yes (except `itop-http`):

| Name | Check command | Interval | Retry | Attempts |
|------|---------------|----------|-------|----------|
| `file-age` | check_file_age | 1h | 10m | 2 |
| `archive-integrity` | check_archive_integrity | 24h | 1h | 2 |
| `itop-cron` | check_itop_cron | 1h | 15m | 2 |
| `itop-replica-errors` | check_itop_replica_errors | 1h | 15m | 2 |
| `itop-mail` | check_itop_mail | 1h | 15m | 2 |

Give `archive-integrity` a **Check timeout of 10m** — it reads the whole
archive.

### 3. Create the Host Template

**Hosts > Host Templates > + Add**:

```
Name:          itop-host
Check command: hostalive
```

On the **Custom Properties** tab add the variables from
`host_template.conf` — `itop`, the `itop_db_*` group, `itop_http_*`,
`itop_backup_*`, `itop_containers`, `itop_healthy_container` and
`itop_mail_*`. Set `itop_containers` and `itop_mail_forbid_hosts` as **Array**
fields.

Keep the database password out of Director. Set only
`itop_db_defaults_file` to the path of the mode 0600 file on the agent.

### 4. Create the Service Set

**Services > Service Sets > + Add**:

```
Name:        iTop
Description: Application-level checks for an iTop instance
```

Add one service per row of the table at the top of this document, each importing
the matching template. Then assign the set to hosts:

```
host.templates contains "itop-host"
```

or `host.vars.itop is true`.

A Service Set is the Director equivalent of `services.conf` — it keeps the nine
services together so they are added, removed and assigned as one unit.

### 5. Deploy

Click **Deploy**. Changes in Director are not active until deployed.

## Notes on three decisions

**The HTTP check must traverse the VIP.** It runs from the master, not the
agent, and is pointed at the public hostname. A break *between* the load
balancer and the backend leaves every component individually healthy; only an
end-to-end request sees it.

**The container check is level-based, and split three ways.** A container
restarting every thirty seconds is still `running`, so running-state alone is
the weakest of the available signals. `--uptime` catches a crash loop as a
*level*: a bouncing container always has a recent start time, so the condition
holds for as long as the fault does. A check that fired on the *change* in
restart count instead would go CRITICAL for one poll and OK on the next, never
surviving `max_check_attempts`, and would therefore never notify at all.

It is split because `--health` returns UNKNOWN for a container that has no
healthcheck — only the database container defines one — and because the cron
container sits behind a compose profile and may legitimately be absent.

**Replica errors alert above a baseline, not above zero.** Real instances carry
stable, understood synchro faults. Alerting on non-zero would alert
permanently, and a permanent alert is muted within a week. Read the current
counts and record them deliberately:

```
mysql --defaults-file=/etc/icinga2/itop-ro.cnf -h 127.0.0.1 itop -N -B -e \
  "SELECT sync_source_id, SUM(status_last_error <> '') FROM priv_sync_replica GROUP BY sync_source_id;"
```

See [check_itop_replica_errors/INSTALL.md](../../plugins/bash/check_itop_replica_errors/INSTALL.md#establishing-the-baselines)
for how to classify each source.

## After the set is live

If the instance has interim alerting — cron jobs mailing a person directly on
backup or sync failure — remove it once checks 2, 3 and 5 are confirmed working.
Two alerting paths with different thresholds and different destinations is worse
than one, and the whole point of moving them into Icinga is to have a single
authoritative path.

## License
MIT — see [LICENSE](../../LICENSE)
