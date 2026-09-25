# Installation Guide: check_file_age

## Table of Contents
- [Requirements](#requirements)
- [Plugin Installation](#plugin-installation)
- [Read Access to the Directory](#read-access-to-the-directory)
- [Method 1: Config File Deployment](#method-1-config-file-deployment)
- [Method 2: Icinga Director (UI)](#method-2-icinga-director-ui)
- [Verification](#verification)

## Requirements
- Icinga 2 >= 2.13.0
- Bash >= 4.x
- GNU `find` (`findutils`) and `timeout` (`coreutils`)
- Read access to the watched directory — see below

## Plugin Installation

```
cp check_file_age.sh /usr/lib64/nagios/plugins/check_file_age
chmod +x /usr/lib64/nagios/plugins/check_file_age
```

> **Plugin path:** these examples use the AlmaLinux 9 path `/usr/lib64/nagios/plugins`
> (the 64-bit RHEL-family `PluginDir`). On Debian/Ubuntu it is `/usr/lib/nagios/plugins`
> — confirm your distribution's `PluginDir` constant and adjust the paths accordingly.
> The sudoers rule below must use the same path.

The check reads a local directory, so install it on the node that holds the
files and route the check with `command_endpoint`, not on the Icinga master.

## Read Access to the Directory

Backup directories are commonly `mode 700 root:root`, with the files themselves
mode 600. The `icinga` user then cannot even stat them, and the check would
report UNKNOWN forever.

Grant exactly one command, naming the exact path:

```
# /etc/sudoers.d/icinga-check_file_age
icinga ALL = (root) NOPASSWD: /usr/lib64/nagios/plugins/check_file_age
```

```
chmod 0440 /etc/sudoers.d/icinga-check_file_age
visudo -c
```

Then invoke the plugin through sudo by overriding the command in the
CheckCommand:

```
object CheckCommand "check_file_age" {
  command = [ "sudo", PluginDir + "/check_file_age" ]
  ...
}
```

Do **not** loosen the permissions on the backup directory instead. Widening
read access to every backup in order to satisfy a monitoring check is a much
larger change than a single sudoers line.

## Method 1: Config File Deployment

### CheckCommand Definition

```
cp icinga2/checkcommand.conf /etc/icinga2/conf.d/check_file_age_command.conf
```

See `icinga2/checkcommand.conf` for full contents.

### Service Template

```
cp icinga2/service_template.conf /etc/icinga2/conf.d/check_file_age_service_template.conf
```

Defines `template Service "file-age"` — an hourly poll with
`command_endpoint = host.name`. A freshness check is a level check against a
slow-moving fact; polling it by the minute buys nothing and only multiplies the
cost of a directory scan.

### Service Definition

```
cp icinga2/service.conf /etc/icinga2/conf.d/check_file_age_service.conf
```

Adjust the `assign where` rule to match your environment before deploying. Set
the per-host values, for example:

```
object Host "backup-node" {
  import "generic-host"
  address = "10.0.0.10"

  vars.file_age_path    = "/backups"
  vars.file_age_pattern = "itop-db-*.sql.gz"
  vars.file_age_warning = 26
  vars.file_age_critical = 50
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
   Name:        check_file_age
   Command:     $USER1$/check_file_age
   Description: Age of the newest file matching a glob; detects absence
   ```

   If you are using the sudoers route above, set the command to
   `sudo $USER1$/check_file_age`.

4. Switch to the **Arguments** tab and add each argument below. *Type* is the
   Director value type, *Required* mirrors the CheckCommand, *Repeat key*
   (`repeat_key`) applies to array arguments (none here), and *Skip key* is the
   `set_if` boolean that gates a flag argument (none here — every argument
   carries a value):

   | Argument     | Value                     | Type   | Required | Repeat key | Skip key (set_if) | Description                                              |
   |--------------|---------------------------|--------|----------|------------|-------------------|----------------------------------------------------------|
   | `-p`         | `$file_age_path$`         | String | Yes      | No         | —                 | Directory to look in (not recursive)                     |
   | `--pattern`  | `$file_age_pattern$`      | String | Yes      | No         | —                 | Filename glob, e.g. `itop-db-*.sql.gz`                   |
   | `-w`         | `$file_age_warning$`      | Number | No       | No         | —                 | Warning threshold, age in hours (default 26)             |
   | `-c`         | `$file_age_critical$`     | Number | No       | No         | —                 | Critical threshold, age in hours (default 50)            |
   | `--min-bytes`| `$file_age_min_bytes$`    | Number | No       | No         | —                 | Newest match smaller than this is CRITICAL (default 1)   |
   | `-t`         | `$file_age_timeout$`      | Number | No       | No         | —                 | Timeout in seconds (default 30)                          |

5. Click **Store**

### Create Service Template

1. Navigate to **Icinga Director > Services > Service Templates**
2. Click **+ Add**
3. Fill in:

   ```
   Name:          file-age
   Check command: check_file_age
   Run on agent:  yes
   Check interval: 1h
   Retry interval: 10m
   Max check attempts: 2
   ```

4. Click **Store**

### Create Service

1. Navigate to **Icinga Director > Services > Apply Rules**
2. Click **+ Add**
3. Fill in:

   ```
   Name:           file-age
   Imports:        file-age
   ```

4. Switch to the **Custom Properties** tab and set `file_age_path` and
   `file_age_pattern` (leave the thresholds unset to inherit the CheckCommand
   defaults)
5. Switch to the **Assign** tab and add a rule, e.g. `host.vars.file_age` is true
6. Click **Store**, then **Deploy**

Always trigger a **Deploy** after changes in Director. Changes are not active
until deployed.

## Verification

```
/usr/lib64/nagios/plugins/check_file_age -p /backups --pattern 'itop-db-*.sql.gz'
```

Expected output:

```
check_file_age OK - itop-db-2026-09-25_2330.sql.gz is 3h old, 7 match(es) | age_seconds=10800s;93600;180000;0 matched_files=7 newest_bytes=418234901B
```

Run it as the Icinga user, which is what will actually execute it:

```
sudo -u icinga /usr/lib64/nagios/plugins/check_file_age -p /backups --pattern 'itop-db-*.sql.gz'
```

An UNKNOWN saying the directory "is not readable by icinga" means the sudoers
step above has not been applied.

Confirm the absence path works, since it is the reason the check exists:

```
/usr/lib64/nagios/plugins/check_file_age -p /backups --pattern 'no-such-file-*'
echo $?   # expect 2, with "the job produced nothing"
```

Then check the object is live:

```
icinga2 object list --type Service --name "file-age"
journalctl -u icinga2 -f
```
