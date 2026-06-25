# Installation Guide: check_cnx_docs

## Table of Contents

- Requirements
- Plugin Installation
- File Access (instances.cfg)
- Grace period for sym_monitor restarts
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
- Bash >= 4.x
- `pgrep` (package `procps` on RHEL/Rocky, `procps` on Debian/Ubuntu)
- `grep`, `timeout` (from GNU coreutils — Linux only)
- HCL Connections Docs Conversion server with `sym_monitor` configured
  and a populated `instances.cfg`
- Install the plugin **on the Conversion node itself**, not on the
  Icinga master — `pgrep` only sees processes on the local host

## Plugin Installation

```bash
cp check_cnx_docs.sh /usr/lib64/nagios/plugins/check_cnx_docs
chmod +x /usr/lib64/nagios/plugins/check_cnx_docs
```

> **Plugin path:** these examples use the AlmaLinux 9 path `/usr/lib64/nagios/plugins`
> (the 64-bit RHEL-family `PluginDir`). On Debian/Ubuntu it is `/usr/lib/nagios/plugins`
> — confirm your distribution's `PluginDir` constant and adjust the paths accordingly.

If using a satellite/agent setup, install on the node executing the
check.

## File Access (instances.cfg)

The plugin reads `/opt/Conversion/symphony/sym_monitor/instances.cfg`
to autodetect the expected soffice count. The icinga agent user must
be able to read it. Two options:

**Option A — relax file permissions (simplest if policy allows):**

```bash
chmod o+r /opt/Conversion/symphony/sym_monitor/instances.cfg
```

**Option B — group ACL (preferred on hardened systems):**

```bash
setfacl -m u:icinga:r /opt/Conversion/symphony/sym_monitor/instances.cfg
getfacl /opt/Conversion/symphony/sym_monitor/instances.cfg
```

`pgrep` already sees processes from other users on a default Linux
install. If `/proc` is mounted with `hidepid=2`, add the icinga user
to the group authorised by the `gid=` mount option, or relax `hidepid`.

The state file (default `/tmp/check_cnx_docs.state`) must also be
writable by the icinga user. `/tmp` is by default, so no extra setup
is needed in most environments. If you point `--state-file` elsewhere,
make sure the parent directory is writable.

## Grace period for sym_monitor restarts

If `sym_monitor` is restarted by a cron job (e.g. every 5 minutes), the
default `--sym-monitor-grace-seconds 300` suppresses CRITICAL while the
watchdog has been down for ≤ 5 minutes. After that it pages normally.

Two ways to implement the grace, depending on your preference:

**Plugin-side (default)** — the plugin tracks first-seen-down in
`/tmp/check_cnx_docs.state` and stays OK during the window. Self-
contained, no Icinga config changes needed:

```
vars.check_cnx_docs_sym_monitor_grace_seconds = 300
vars.check_cnx_docs_state_file                = "/tmp/check_cnx_docs.state"
```

To match a cron interval other than 5 minutes, adjust the grace seconds
to slightly exceed your cron period (e.g. `360` for a 5-minute cron, to
allow a tick to be missed by a few seconds).

**Icinga-native alternative** — disable the plugin's grace
(`--sym-monitor-grace-seconds 0`) and let Icinga's soft→hard state
machine absorb the restart window:

```icinga2
apply Service "check_cnx_docs" {
  check_command           = "check_cnx_docs"
  check_interval          = 1m
  retry_interval          = 1m
  max_check_attempts      = 6     // 6 attempts × 1m ≈ 5 min grace
  vars.check_cnx_docs_sym_monitor_grace_seconds = 0
  // ... rest unchanged
}
```

With this, Icinga shows CRITICAL (soft) immediately, but only fires
notifications once the state goes HARD after 6 consecutive failures.
Operators still see the issue in the UI during the grace window — pick
this if you'd rather have full visibility over a silent grace.

Note: in both modes, the **soffice** sub-check has no grace. It will
report CRITICAL while sym_monitor is being restarted because workers
can't run without their parent. If that creates noise, either disable
the soffice sub-check for the duration (`--no-soffice`) or rely on the
Icinga-native approach above (which suppresses notifications for the
entire service, not just sym_monitor).

## Method 1: Config File Deployment

### CheckCommand Definition

```bash
cp icinga2/checkcommand.conf /etc/icinga2/conf.d/check_cnx_docs_command.conf
```

See [icinga2/checkcommand.conf](icinga2/checkcommand.conf) for full
contents.

### Host Template

```bash
cp icinga2/host_template.conf /etc/icinga2/conf.d/check_cnx_docs_host_template.conf
```

See [icinga2/host_template.conf](icinga2/host_template.conf) for full
contents.

### Service Definition

```bash
cp icinga2/service.conf /etc/icinga2/conf.d/check_cnx_docs_service.conf
```

See [icinga2/service.conf](icinga2/service.conf) for full contents.

The default `assign where` rule applies the service to every host with
`host.vars.check_cnx_docs == true`. Either set that var on each
Conversion host, or switch to the template-based rule (commented in
the file).

Validate and reload Icinga 2:

```bash
icinga2 daemon --validate
systemctl reload icinga2
```

## Method 2: Icinga Director (UI)

Assumes Icinga Director is installed and Kickstart wizard completed.
Minimum supported Director version: 1.10.0

### Create CheckCommand

1. Navigate to **Icinga Director > Commands > External Commands**
2. Click **+ Add**
3. Fill in:

   ```
   Name:        check_cnx_docs
   Command:     $USER1$/check_cnx_docs
   Description: HCL Connections Docs Conversion server health (sym_monitor + soffice)
   ```

4. Switch to **Arguments** tab and add:

   | Argument                      | Value                                              | Required | Description |
   |-------------------------------|----------------------------------------------------|----------|-------------|
   | `--instances-cfg`             | `$check_cnx_docs_instances_cfg$`                   | No       | Path to instances.cfg |
   | `--sym-monitor-pattern`       | `$check_cnx_docs_sym_monitor_pattern$`             | No       | pgrep -f pattern for sym_monitor |
   | `--soffice-pattern`           | `$check_cnx_docs_soffice_pattern$`                 | No       | pgrep -f pattern for soffice |
   | `--sym-monitor-grace-seconds` | `$check_cnx_docs_sym_monitor_grace_seconds$`       | No       | Suppress CRITICAL while sym_monitor has been down ≤ N s (0 disables) |
   | `--state-file`                | `$check_cnx_docs_state_file$`                      | No       | State file path for sym_monitor first-down timestamp |
   | `-t`                          | `$check_cnx_docs_timeout$`                         | No       | Timeout in seconds |
   | `--no-sym-monitor`            | `$check_cnx_docs_no_sym_monitor$` (set_if)         | No       | Disable the sym_monitor sub-check |
   | `--no-soffice`                | `$check_cnx_docs_no_soffice$` (set_if)             | No       | Disable the soffice sub-check |

5. Click **Store** then **Deploy**

### Create Host Template

1. Navigate to **Icinga Director > Hosts > Host Templates**
2. Click **+ Add**
3. Fill in:

   ```
   Name:          cnx-docs-conversion-host
   Check command: hostalive
   ```

4. Switch to **Custom Properties** tab and add:

   ```
   check_cnx_docs                           = true
   check_cnx_docs_instances_cfg             = /opt/Conversion/symphony/sym_monitor/instances.cfg
   check_cnx_docs_sym_monitor_grace_seconds = 300
   check_cnx_docs_state_file                = /tmp/check_cnx_docs.state
   check_cnx_docs_timeout                   = 30
   ```

5. Click **Store**

### Create Service

1. Navigate to **Icinga Director > Services > Apply Rules**
2. Click **+ Add**
3. Fill in:

   ```
   Name:          check_cnx_docs
   Check command: check_cnx_docs
   ```

4. Switch to **Assign** tab and add rule:
   - `host.vars.check_cnx_docs` is `true`
   - or: `host.templates` contains `cnx-docs-conversion-host`

5. Click **Store** then **Deploy**

Always trigger a **Deploy** after changes in Director — changes are not
active until deployed.

## Verification

On the Conversion host:

```bash
# Confirm instances.cfg is readable as the icinga user
sudo -u icinga cat /opt/Conversion/symphony/sym_monitor/instances.cfg

# Confirm the icinga user can see soffice / sym_monitor
sudo -u icinga pgrep -fa soffice
sudo -u icinga pgrep -fa sym_monitor

# Run the plugin as the icinga user
sudo -u icinga /usr/lib64/nagios/plugins/check_cnx_docs
echo "exit=$?"
```

Expected (healthy) output:

```
check_cnx_docs OK - sym_monitor=OK soffice=OK | sym_monitor_procs=1 soffice_procs=3;3;; soffice_expected=3
[OK] sym_monitor: 1 process(es) running
[OK] soffice: 3 of 3 expected processes running (from instances.cfg)
```

Then confirm Icinga 2 picked up the service:

```bash
icinga2 object list --type Service --name "check_cnx_docs"
journalctl -u icinga2 -f
```
