# Installation Guide: check_itop_mail

## Table of Contents
- [Requirements](#requirements)
- [Plugin Installation](#plugin-installation)
- [Read Access to config-itop.php](#read-access-to-config-itopphp)
- [Database Access](#database-access)
- [Method 1: Config File Deployment](#method-1-config-file-deployment)
- [Method 2: Icinga Director (UI)](#method-2-icinga-director-ui)
- [Verification](#verification)

## Requirements
- Icinga 2 >= 2.13.0
- Bash >= 4.x, `awk`, `timeout`
- A `mysql` or `mariadb` client (only if the database half is enabled)
- Read access to `config-itop.php`
- TCP access to the iTop database, and a read-only database user

## Plugin Installation

```
cp check_itop_mail.sh /usr/lib64/nagios/plugins/check_itop_mail
chmod +x /usr/lib64/nagios/plugins/check_itop_mail
```

> **Plugin path:** these examples use the AlmaLinux 9 path `/usr/lib64/nagios/plugins`
> (the 64-bit RHEL-family `PluginDir`). On Debian/Ubuntu it is `/usr/lib/nagios/plugins`
> — confirm your distribution's `PluginDir` constant and adjust the paths accordingly.
> The sudoers rule below must use the same path.

## Read Access to config-itop.php

On a containerised deployment the file lives on the host at a path such as:

```
/data/itop_migration/conf/production/config-itop.php
```

and is typically **mode 440 owned by the web user (uid 33)**, so the `icinga`
user cannot read it.

Grant exactly one command, naming the exact path:

```
# /etc/sudoers.d/icinga-check_itop_mail
icinga ALL = (root) NOPASSWD: /usr/lib64/nagios/plugins/check_itop_mail
```

```
chmod 0440 /etc/sudoers.d/icinga-check_itop_mail
visudo -c
```

Then invoke the plugin through sudo in the CheckCommand:

```
object CheckCommand "check_itop_mail" {
  command = [ "sudo", PluginDir + "/check_itop_mail" ]
  ...
}
```

Do not loosen the permissions on `config-itop.php` instead — it contains the
application's database password and encryption key.

The plugin does **not** need PHP. It parses the settings directly, because on a
containerised deployment the interpreter is inside the application container
rather than on the host.

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

Recreate the container for the change to take effect.

### 2. Create a read-only user

This check reads the event log only:

```sql
CREATE USER 'icinga_ro'@'127.0.0.1' IDENTIFIED BY 'choose-a-strong-password';
GRANT SELECT ON itop.priv_event TO 'icinga_ro'@'127.0.0.1';
FLUSH PRIVILEGES;
```

`priv_event` is the parent table whose `message` column carries the delivery
verdict. `priv_event_email` is **not** used: its schema varies between iTop
versions and carries no reliable failure column.

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

If only one half is available in your environment, run the check with
`--no-db` or `--no-config` rather than leaving it half-configured.

## Method 1: Config File Deployment

### CheckCommand Definition

```
cp icinga2/checkcommand.conf /etc/icinga2/conf.d/check_itop_mail_command.conf
```

### Service Template

```
cp icinga2/service_template.conf /etc/icinga2/conf.d/check_itop_mail_service_template.conf
```

Defines `template Service "itop-mail"` — hourly. The configuration half is drift
detection, so a fast poll buys nothing.

### Service Definition

```
cp icinga2/service.conf /etc/icinga2/conf.d/check_itop_mail_service.conf
```

```
object Host "helpdesk" {
  import "generic-host"
  address = "10.7.102.60"

  vars.itop                  = true
  vars.itop_db_host          = "127.0.0.1"
  vars.itop_db_name          = "itop"
  vars.itop_db_defaults_file = "/etc/icinga2/itop-ro.cnf"

  vars.itop_mail_config           = "/data/itop_migration/conf/production/config-itop.php"
  vars.itop_mail_forbid_hosts     = [ "mailpit", "localhost", "127.0.0.1" ]
  vars.itop_mail_expect_transport = "SMTP"
}
```

`itop_mail_forbid_hosts` is an array — the CheckCommand repeats `--forbid-host`
once per element.

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
   Name:        check_itop_mail
   Command:     $USER1$/check_itop_mail
   Description: Is iTop mail leaving the host, and not going to a capture sink?
   ```

   If you are using the sudoers route above, set the command to
   `sudo $USER1$/check_itop_mail`.

4. Switch to the **Arguments** tab and add each argument below. *Type* is the
   Director value type, *Required* mirrors the CheckCommand, *Repeat key*
   (`repeat_key`) applies to array arguments — Director repeats the flag once
   per array element — and *Skip key* shows the `set_if` boolean that gates a
   flag argument (boolean flags carry no value; set them only via their `set_if`
   var):

   | Argument                | Value                             | Type    | Required | Repeat key | Skip key (set_if)          | Description                                                       |
   |-------------------------|-----------------------------------|---------|----------|------------|----------------------------|-------------------------------------------------------------------|
   | `--config`              | `$itop_mail_config$`              | String  | Yes*     | No         | —                          | Path to `config-itop.php` (*unless `--no-config` is set)          |
   | `--expect-transport`    | `$itop_mail_expect_transport$`    | String  | No       | No         | —                          | Transport meaning mail leaves the host (default SMTP)             |
   | `--forbid-host`         | `$itop_mail_forbid_hosts$`        | Array   | No       | **Yes**    | —                          | Relay hostname that is a capture sink, e.g. `mailpit`             |
   | `--expect-verify-peer`  | `$itop_mail_expect_verify_peer$`  | String  | No       | No         | —                          | Assert `verify_peer` is 0 or 1; omit to skip                      |
   | `--no-config`           | (none)                            | Boolean | No       | No         | `$itop_mail_no_config$`    | Skip the configuration half                                       |
   | `--no-db`               | (none)                            | Boolean | No       | No         | `$itop_mail_no_db$`        | Skip the database half                                            |
   | `-H`                    | `$itop_db_host$`                  | String  | No       | No         | —                          | Database host (default 127.0.0.1)                                 |
   | `-P`                    | `$itop_db_port$`                  | Number  | No       | No         | —                          | Database port (default 3306)                                      |
   | `-d`                    | `$itop_db_name$`                  | String  | No       | No         | —                          | Database name (default itop)                                      |
   | `-u`                    | `$itop_db_user$`                  | String  | No       | No         | —                          | Database user; omit if the defaults file supplies it              |
   | `--defaults-file`       | `$itop_db_defaults_file$`         | String  | No       | No         | —                          | my.cnf-style credentials file, mode 0600                          |
   | `--window-hours`        | `$itop_mail_window_hours$`        | Number  | No       | No         | —                          | How far back to look for send failures (default 1)                |
   | `--failure-prefix`      | `$itop_mail_failure_prefix$`      | String  | No       | No         | —                          | `priv_event.message` prefix marking a real failure                |
   | `-w`                    | `$itop_mail_warning$`             | Number  | No       | No         | —                          | Warning threshold, failure count (default 1)                      |
   | `-c`                    | `$itop_mail_critical$`            | Number  | No       | No         | —                          | Critical threshold; unset = never CRITICAL                        |
   | `-t`                    | `$itop_db_timeout$`               | Number  | No       | No         | —                          | Query timeout in seconds (default 30)                             |

5. Click **Store**

Sensitive values: keep the database password in the mode 0600 defaults file on
the agent and reference only its path.

### Create Service Template

1. Navigate to **Icinga Director > Services > Service Templates**
2. Click **+ Add**
3. Fill in:

   ```
   Name:               itop-mail
   Check command:      check_itop_mail
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
   Name:    itop-mail
   Imports: itop-mail
   ```

4. Switch to the **Custom Properties** tab and set `itop_mail_config` and
   `itop_mail_forbid_hosts` (as an Array — Director will repeat the flag)
5. Switch to the **Assign** tab and add: `host.vars.itop` is true
6. Click **Store**, then **Deploy**

To deploy this alongside the rest of the iTop checks, add it to a Director
**Service Set** instead — see `servicesets/itop/README.md`.

## Verification

```
/usr/lib64/nagios/plugins/check_itop_mail \
  --config /data/itop_migration/conf/production/config-itop.php \
  --forbid-host mailpit \
  -H 127.0.0.1 -d itop --defaults-file /etc/icinga2/itop-ro.cnf
```

Expected output on a live instance:

```
check_itop_mail OK - config=OK sends=OK | mail_sink=0 email_failures=0;1;;0
[OK] transport SMTP, relay 'smtp.ams.cloud' is not a sink
[OK] no send failures in the last 1h
```

Run it as the user that will actually execute it:

```
sudo -u icinga /usr/lib64/nagios/plugins/check_itop_mail --config ... --no-db
```

An UNKNOWN saying the config "is not readable by icinga" means the sudoers step
above has not been applied.

**Confirm the sink assertion can fire**, using a copy rather than the live file:

```
sed 's/smtp\.ams\.cloud/mailpit/' \
    /data/itop_migration/conf/production/config-itop.php > /tmp/probe.php
/usr/lib64/nagios/plugins/check_itop_mail --config /tmp/probe.php \
    --forbid-host mailpit --no-db
echo $?   # expect 2, "a configured capture sink"
rm -f /tmp/probe.php
```

Check the failure wording matches your instance before trusting the send half —
it is a prefix match on free text:

```
mysql --defaults-file=/etc/icinga2/itop-ro.cnf -h 127.0.0.1 itop -e \
  "SELECT LEFT(message,60), COUNT(*) FROM priv_event GROUP BY LEFT(message,60);"
```

`Sent` means the relay accepted it, `No recipient` is normal and is not counted,
and anything beginning `Sending eMail failed` is a real failure. If your
instance words it differently, set `--failure-prefix`.

Then check the object is live:

```
icinga2 object list --type Service --name "itop-mail"
journalctl -u icinga2 -f
```
