# Installation Guide: check_acronis_disabled

## Table of Contents
- Requirements
- Root access (sudo) for aakore
- Plugin Installation
- Method 1: Config File Deployment
- Method 2: Icinga Director (UI)
- Verification

## Requirements
- Icinga 2 >= 2.13.0
- Bash >= 4.x
- Runs **locally on the host** running the Acronis agent (install on the Icinga
  agent there, not the master)
- Linux with `/proc` (used for tray-process detection)
- `systemctl`, `awk`, `timeout` (coreutils) — all present on a stock AlmaLinux 9
- **root** to read the aakore unit state — see below

### Confirm the component names/paths
The defaults match a stock Acronis agent. Confirm on your host and override with
`--service` / `--unit` / `--tray-bin` / `--aakore` if they differ:
```
systemctl is-active  cyber-protect-service.service
systemctl is-enabled cyber-protect-service.service
# The plugin matches the tray by its argv[0]; show argv[0] of any candidate:
for p in $(pgrep -f cyber-desktop-service-qt6); do tr '\0' ' ' < /proc/$p/cmdline; echo " [pid $p]"; done
sudo /opt/acronis/aakore units | awk '$1=="cyber-desktop-service"'
```
The `aakore units` output has two `cyber-desktop-service` rows: the **local**
managed unit (`STAT` starts with `+`/`-`) and a cloud-registration reference
(`STAT` exactly `+X`). The plugin parses only the local row and ignores `+X`.

## Root access (sudo) for aakore

`/opt/acronis/aakore units` requires root. The Icinga agent usually runs as an
unprivileged `icinga`/`nagios` user, so grant it a narrow sudo rule and have
Icinga invoke the plugin via `sudo`.

Add a file under `/etc/sudoers.d/` (validate with `visudo -c`):
```
# /etc/sudoers.d/icinga-check_acronis_disabled
icinga ALL=(root) NOPASSWD: /usr/lib64/nagios/plugins/check_acronis_disabled
```
Then set the CheckCommand to run via sudo (see the note at the top of
`icinga2/checkcommand.conf`), e.g. `command = [ "sudo", PluginDir + "/check_acronis_disabled" ]`
(or prefix with `sudo` in Director). Scope the sudo rule to this one plugin.

> **Without root** the plugin still works: it falls back to the tray *process*
> check (via `/proc`, no root needed) and reports the aakore unit state as
> `unavailable (core down or not root)`. It will still WARN if the tray process
> is running — it just cannot see the persisted enabled/disabled state. Granting
> the sudo rule above gives full coverage.

## Plugin Installation

```
cp check_acronis_disabled.sh /usr/lib64/nagios/plugins/check_acronis_disabled
chmod +x /usr/lib64/nagios/plugins/check_acronis_disabled
```

> **Plugin path:** these examples use the AlmaLinux 9 path `/usr/lib64/nagios/plugins`
> (the 64-bit RHEL-family `PluginDir`). On Debian/Ubuntu it is `/usr/lib/nagios/plugins`
> — confirm your distribution's `PluginDir` constant and adjust the paths accordingly.
> The sudoers rule above must use the same path.

## Method 1: Config File Deployment

### CheckCommand Definition
```
cp icinga2/checkcommand.conf /etc/icinga2/conf.d/check_acronis_disabled_command.conf
```
See `icinga2/checkcommand.conf` for full contents (including the `sudo` note).

### Service Definition
```
cp icinga2/service.conf /etc/icinga2/conf.d/check_acronis_disabled_service.conf
```

Flag the hosts that run the Acronis agent, e.g.:
```
object Host "app01.example.com" {
  import "generic-host"
  address = "10.0.0.20"
  vars.acronis_backup = true
}
```

Validate and reload:
```
icinga2 daemon --validate
systemctl reload icinga2
```

## Method 2: Icinga Director (UI)

Assumes Icinga Director >= 1.10.0 with the Kickstart wizard completed.

### Create CheckCommand
1. Director > Commands > External Commands > **+ Add**
2. Name: `check_acronis_disabled`, Command: `$USER1$/check_acronis_disabled`
   (or `sudo $USER1$/check_acronis_disabled` to read the aakore unit state)
3. Arguments tab — add each argument below. *Type* is the Director value type,
   *Required* mirrors the CheckCommand, *Repeat key* (`repeat_key`) applies to
   array arguments (none here), and *Skip key* is the `set_if` boolean that gates
   a flag argument (none here — every argument carries a value):

   | Argument   | Value                            | Type   | Required | Repeat key | Skip key (set_if) | Description                                     |
   |------------|----------------------------------|--------|----------|------------|-------------------|-------------------------------------------------|
   | --service  | `$acronis_disabled_service$`     | String | No       | No         | —                 | systemd unit for cyber-protect-service          |
   | --unit     | `$acronis_disabled_unit$`        | String | No       | No         | —                 | aakore unit name for the desktop/tray component |
   | --tray-bin | `$acronis_disabled_tray_bin$`    | String | No       | No         | —                 | Tray binary, matched as a process argv[0]       |
   | --aakore   | `$acronis_disabled_aakore$`      | String | No       | No         | —                 | Path to the Acronis agent core CLI              |
   | -t         | `$acronis_disabled_timeout$`     | Number | No       | No         | —                 | Timeout per external command (default 30)       |

4. Set the default Custom Properties on the command (matching the CheckCommand):
   `acronis_disabled_service = cyber-protect-service.service`,
   `acronis_disabled_unit = cyber-desktop-service`,
   `acronis_disabled_tray_bin = /opt/acronis/bin/cyber-desktop-service-qt6`,
   `acronis_disabled_aakore = /opt/acronis/aakore`,
   `acronis_disabled_timeout = 30`.
5. **Store**, then **Deploy**.

### Create Service
1. Director > Services > Apply Rules > **+ Add**
2. Name: `acronis-disabled`, Check command: `check_acronis_disabled`
3. Set `command_endpoint = host.name` (the check runs on the agent) and a relaxed
   interval (e.g. 15m) — this is drift detection, not an outage check.
4. Assign tab: `host.vars.acronis_backup` is true
5. **Store**, then **Deploy**.

Always **Deploy** after changes in Director.

## Verification

Process/config check on the host (as root or via sudo for full coverage):
```
sudo /usr/lib64/nagios/plugins/check_acronis_disabled
```

Expected on a correctly-hardened host:
```
check_acronis_disabled OK - cyber-protect-service inactive/disabled; cyber-desktop-service disabled (STAT -Tr), tray not running | ...
```

On a host without the agent (safe — the check is broadly applicable):
```
check_acronis_disabled OK - Acronis agent not installed - nothing to check
```

If a component has come back you will see `WARNING` with the offending component
named (e.g. `cyber-protect-service active/enabled` or `tray running (pid ...)`).

```
icinga2 object list --type Service --name "acronis-disabled"
journalctl -u icinga2 -f
```
