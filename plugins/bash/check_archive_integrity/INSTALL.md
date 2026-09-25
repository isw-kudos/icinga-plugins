# Installation Guide: check_archive_integrity

## Table of Contents
- [Requirements](#requirements)
- [Plugin Installation](#plugin-installation)
- [Read Access to the Archives](#read-access-to-the-archives)
- [Method 1: Config File Deployment](#method-1-config-file-deployment)
- [Method 2: Icinga Director (UI)](#method-2-icinga-director-ui)
- [Verification](#verification)

## Requirements
- Icinga 2 >= 2.13.0
- Bash >= 4.x
- GNU `find` (`findutils`) and `timeout` (`coreutils`)
- The decompressor for the archive type in use — `gzip` is in every base
  install; `bzip2`, `xz`, `tar` and `unzip` may need installing
- Read access to the archives — see below

## Plugin Installation

```
cp check_archive_integrity.sh /usr/lib64/nagios/plugins/check_archive_integrity
chmod +x /usr/lib64/nagios/plugins/check_archive_integrity
```

> **Plugin path:** these examples use the AlmaLinux 9 path `/usr/lib64/nagios/plugins`
> (the 64-bit RHEL-family `PluginDir`). On Debian/Ubuntu it is `/usr/lib/nagios/plugins`
> — confirm your distribution's `PluginDir` constant and adjust the paths accordingly.
> The sudoers rule below must use the same path.

Install it on the node that holds the archives and route the check with
`command_endpoint`, not on the Icinga master.

## Read Access to the Archives

Backup archives are typically mode `600` inside a mode `700 root:root`
directory, so the `icinga` user cannot read them and the check would report
UNKNOWN forever.

Grant exactly one command, naming the exact path:

```
# /etc/sudoers.d/icinga-check_archive_integrity
icinga ALL = (root) NOPASSWD: /usr/lib64/nagios/plugins/check_archive_integrity
```

```
chmod 0440 /etc/sudoers.d/icinga-check_archive_integrity
visudo -c
```

Then invoke the plugin through sudo in the CheckCommand:

```
object CheckCommand "check_archive_integrity" {
  command = [ "sudo", PluginDir + "/check_archive_integrity" ]
  ...
}
```

## Method 1: Config File Deployment

### CheckCommand Definition

```
cp icinga2/checkcommand.conf /etc/icinga2/conf.d/check_archive_integrity_command.conf
```

See `icinga2/checkcommand.conf` for full contents.

### Service Template

```
cp icinga2/service_template.conf /etc/icinga2/conf.d/check_archive_integrity_service_template.conf
```

Defines `template Service "archive-integrity"` — a **daily** poll with a 10
minute `check_timeout`. The decompression test reads the whole archive, so on a
large dump this is the most expensive check in the set. Correctness does not
depend on when it runs: `--min-age-seconds` keeps it off a half-written file
regardless of scheduling.

### Service Definition

```
cp icinga2/service.conf /etc/icinga2/conf.d/check_archive_integrity_service.conf
```

Adjust the `assign where` rule before deploying, and set the per-host values:

```
object Host "backup-node" {
  import "generic-host"
  address = "10.0.0.10"

  vars.archive_integrity_path    = "/backups"
  vars.archive_integrity_pattern = "itop-db-*.sql.gz"
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
   Name:        check_archive_integrity
   Command:     $USER1$/check_archive_integrity
   Description: Decompression test and checksum sidecar check for the newest archive
   ```

   If you are using the sudoers route above, set the command to
   `sudo $USER1$/check_archive_integrity`.

4. Switch to the **Arguments** tab and add each argument below. *Type* is the
   Director value type, *Required* mirrors the CheckCommand, *Repeat key*
   (`repeat_key`) applies to array arguments (none here), and *Skip key* is the
   `set_if` boolean that gates a flag argument (none here — every argument
   carries a value):

   | Argument             | Value                                      | Type   | Required | Repeat key | Skip key (set_if) | Description                                                     |
   |----------------------|--------------------------------------------|--------|----------|------------|-------------------|-----------------------------------------------------------------|
   | `-p`                 | `$archive_integrity_path$`                 | String | Yes      | No         | —                 | Directory to look in (not recursive)                            |
   | `--pattern`          | `$archive_integrity_pattern$`              | String | Yes      | No         | —                 | Filename glob, e.g. `itop-db-*.sql.gz`                          |
   | `--sidecar-ext`      | `$archive_integrity_sidecar_ext$`          | String | No       | No         | —                 | Sidecar suffix (default `.sha256`); empty string skips it       |
   | `--min-age-seconds`  | `$archive_integrity_min_age_seconds$`      | Number | No       | No         | —                 | Never test an archive younger than this (default 300)           |
   | `-t`                 | `$archive_integrity_timeout$`              | Number | No       | No         | —                 | Timeout for the decompression test (default 300)                |

5. Click **Store**

### Create Service Template

1. Navigate to **Icinga Director > Services > Service Templates**
2. Click **+ Add**
3. Fill in:

   ```
   Name:               archive-integrity
   Check command:      check_archive_integrity
   Run on agent:       yes
   Check interval:     24h
   Retry interval:     1h
   Max check attempts: 2
   Check timeout:      10m
   ```

4. Click **Store**

### Create Service

1. Navigate to **Icinga Director > Services > Apply Rules**
2. Click **+ Add**
3. Fill in:

   ```
   Name:    archive-integrity
   Imports: archive-integrity
   ```

4. Switch to the **Custom Properties** tab and set `archive_integrity_path` and
   `archive_integrity_pattern`
5. Switch to the **Assign** tab and add a rule, e.g. `host.vars.archive_integrity`
   is true
6. Click **Store**, then **Deploy**

Always trigger a **Deploy** after changes in Director.

## Verification

```
/usr/lib64/nagios/plugins/check_archive_integrity -p /backups --pattern 'itop-db-*.sql.gz'
```

Expected output:

```
check_archive_integrity OK - tested itop-db-2026-09-25_2330.sql.gz (7200s old): integrity=OK sidecar=OK | archive_bytes=418234901B tested_age_seconds=7200s integrity_ok=1 sidecar_present=1
```

Run it as the user that will actually execute it:

```
sudo -u icinga /usr/lib64/nagios/plugins/check_archive_integrity -p /backups --pattern 'itop-db-*.sql.gz'
```

If you run it immediately after a backup completes you may legitimately get:

```
check_archive_integrity OK - nothing old enough to test; newest itop-db-2026-09-26_2330.sql.gz is 41s old (min-age 300s), likely still being written
```

That is the concurrency guard working, not a fault. Wait out `--min-age-seconds`
and run it again.

Confirm the failure path detects real corruption, since a check that cannot fail
is worth nothing:

```
cp /backups/itop-db-*.sql.gz /tmp/probe.sql.gz
truncate -s 1024 /tmp/probe.sql.gz
/usr/lib64/nagios/plugins/check_archive_integrity -p /tmp --pattern 'probe.sql.gz' --min-age-seconds 0
echo $?   # expect 2, "failed the decompression test"
rm -f /tmp/probe.sql.gz
```

Then check the object is live:

```
icinga2 object list --type Service --name "archive-integrity"
journalctl -u icinga2 -f
```
