# Installation Guide: check_nfs_mount

## Table of Contents

- Requirements
- Plugin Installation
- Method 1: Config File Deployment
  - CheckCommand Definition
  - Host Template
  - Service Definition
- Method 2: Icinga Director (UI)
  - Create CheckCommand
  - Create Host Template
  - Create Service
- Verification

## Requirements

- Icinga 2 >= 2.13.0
- Python >= 3.8
- Linux only — requires `/proc/mounts` and SIGALRM
- Plugin user must have read access to all checked mount points
- For write check: plugin user must have write permission on the mount

## Plugin Installation

```bash
cp check_nfs_mount.py /usr/lib64/nagios/plugins/check_nfs_mount
chmod +x /usr/lib64/nagios/plugins/check_nfs_mount
```

> **Plugin path:** these examples use the AlmaLinux 9 path `/usr/lib64/nagios/plugins`
> (the 64-bit RHEL-family `PluginDir`). On Debian/Ubuntu it is `/usr/lib/nagios/plugins`
> — confirm your distribution's `PluginDir` constant and adjust the paths accordingly.

If using a satellite/agent setup, install the plugin on the node that has the
NFS mounts — NFS mounts are local to the mounting host. Do not run this check
from the Icinga 2 master unless it also has the mounts.

## Method 1: Config File Deployment

### CheckCommand Definition

```bash
cp icinga2/checkcommand.conf /etc/icinga2/conf.d/check_nfs_mount_command.conf
```

See [icinga2/checkcommand.conf](icinga2/checkcommand.conf) for full contents.

### Host Template

```bash
cp icinga2/host_template.conf /etc/icinga2/conf.d/check_nfs_mount_host_template.conf
```

See [icinga2/host_template.conf](icinga2/host_template.conf) for full contents.

### Service Definition

```bash
cp icinga2/service.conf /etc/icinga2/conf.d/check_nfs_mount_service.conf
```

See [icinga2/service.conf](icinga2/service.conf) for full contents.
Adjust the `assign where` rule to match your environment before deploying.

On each host with NFS mounts, set the required vars:

```icinga2
vars.check_nfs_mount        = true
vars.check_nfs_mount_mounts = [ "/mnt/data", "/mnt/backup" ]
```

For optional write checking:

```icinga2
vars.check_nfs_mount_write = true
```

Validate and reload Icinga 2:

```bash
icinga2 daemon --validate
systemctl reload icinga2
```

### Multiple Mounts Per Host

All mount points are passed to a single check execution via repeated `-m` flags,
handled by `repeat_key = true` in the CheckCommand. Icinga 2 generates:

```
check_nfs_mount -m /mnt/data -m /mnt/backup -t 10
```

The plugin reports overall state as the worst state of any individual mount,
and includes per-mount detail in the output when any mount is not OK.

## Method 2: Icinga Director (UI)

Assumes Icinga Director is installed and Kickstart wizard completed.
Minimum supported Director version: 1.10.0

### Create CheckCommand

1. Navigate to **Icinga Director > Commands > External Commands**
2. Click **+ Add**
3. Fill in:

   ```
   Name:        check_nfs_mount
   Command:     $USER1$/check_nfs_mount
   Description: Checks that NFS mount points are mounted and accessible
   ```

4. Switch to **Arguments** tab and add:

   | Argument | Value                         | Repeat key | Set if                        | Required | Description                 |
   |----------|-------------------------------|------------|-------------------------------|----------|-----------------------------|
   | `-m`     | `$check_nfs_mount_mounts$`    | Yes        |                               | Yes      | NFS mount point(s) to check |
   | `-t`     | `$check_nfs_mount_timeout$`   | No         |                               | No       | Timeout in seconds          |
   | `-w`     |                               | No         | `$check_nfs_mount_write$`     | No       | Verify mount is writable    |
   | `-v`     |                               | No         | `$check_nfs_mount_verbose$`   | No       | Show per-mount detail       |

5. Click **Store** then **Deploy**

### Create Host Template

1. Navigate to **Icinga Director > Hosts > Host Templates**
2. Click **+ Add**
3. Fill in:

   ```
   Name:          nfs-client-host
   Check command: hostalive
   ```

4. Switch to **Custom Properties** tab and add:

   ```
   check_nfs_mount         = true
   check_nfs_mount_timeout = 10
   check_nfs_mount_write   = false
   ```

5. Click **Store**

### Create Service

1. Navigate to **Icinga Director > Services > Apply Rules**
2. Click **+ Add**
3. Fill in:

   ```
   Name:          check_nfs_mount
   Check command: check_nfs_mount
   ```

4. Switch to **Custom Properties** tab:

   ```
   check_nfs_mount_mounts  = (leave blank — set per host as an array)
   check_nfs_mount_timeout = 10
   check_nfs_mount_write   = false
   ```

5. Switch to **Assign** tab and add rule:
   - `host.vars.check_nfs_mount` is `true`
   - or: `host.templates` contains `nfs-client-host`

6. Click **Store** then **Deploy**

Always trigger a **Deploy** after changes in Director. Changes are not active until deployed.

**Setting mount paths per host in Director**: Navigate to the host object, switch to
the **Custom Properties** tab, and set `check_nfs_mount_mounts` as an Array type with
each mount path as an element.

## Verification

```bash
/usr/lib64/nagios/plugins/check_nfs_mount -m /mnt/data -m /mnt/backup -t 10
```

Expected output (all mounts healthy):

```
check_nfs_mount OK - All 2 NFS mount(s) OK | '/mnt/data_response_ms'=1.23ms '/mnt/backup_response_ms'=0.87ms
```

Expected output (stale mount):

```
check_nfs_mount CRITICAL - 1/2 NFS mount(s) OK, 1 CRITICAL | '/mnt/data_response_ms'=1.23ms '/mnt/backup_response_ms'=10003.44ms
[CRITICAL] /mnt/backup (NFS 192.168.1.1:/exports/backup) is unresponsive (timeout after 10s) - likely stale mount
```

```bash
icinga2 object list --type Service --name "check_nfs_mount"
journalctl -u icinga2 -f
```
