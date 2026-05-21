# Installation Guide: check_domino_mail

## Table of Contents

- Requirements
- Prerequisites on the Domino Host
- Plugin Installation
- Method 1: Config File Deployment
  - CheckCommand Definition
  - Host Template
  - Service Definition
- Method 2: Icinga Director (UI)
  - Create CheckCommand
  - Create Host Template
  - Create Service
- Host-Specific Overrides
- Verification

## Requirements

- Icinga 2 >= 2.13.0
- Bash >= 4.x
- HCL Domino >= 14.0 on Linux
- Nashcom Domino start script — `domino` command in PATH
- `python3` (for NRPC handshake probe)
- `curl` (for HTTP probe)
- Icinga 2 agent on the Domino host

## Prerequisites on the Domino Host

### 1. Nashcom start script

The `domino` command must be installed and locatable. Find its path:

```bash
which domino
# typically: /usr/bin/domino or /opt/nashcom/domino/domino
```

### 2. Sudoers entry (required)

The Nashcom start script uses `su` to switch to the `notes` user internally.
When invoked by the Icinga agent user (`nagios` on RHEL, `icinga` on Debian/Ubuntu),
this fails with `su: Authentication failure`. A sudoers entry is required.

Create `/etc/sudoers.d/icinga-domino`:

```
# RHEL / Rocky Linux
nagios ALL=(ALL) NOPASSWD: /usr/bin/domino

# Debian / Ubuntu
icinga ALL=(ALL) NOPASSWD: /usr/bin/domino
```

Adjust the path to match `which domino` on your system.

### 3. Configure the plugin to use sudo

Set `--domino-cmd "sudo domino"` when calling the plugin.

**Config file deployment** — add to each Domino host object:

```icinga2
vars.check_domino_mail_domino_cmd = "sudo domino"
```

**Icinga Director** — set the variable on each Domino host object:

1. Go to **Icinga Director > Hosts**
2. Search for and click on the Domino host (e.g. `mail01.example.com`)
3. Click the **Custom Properties** tab
4. Scroll to the bottom and click **+ Add property**
5. In the **Property name** field type: `check_domino_mail_domino_cmd`
6. In the **Property value** field type: `sudo domino`
7. Click **Add** (the row is saved inline)
8. Click **Store** (top of the form)
9. Click **Deploy** to activate the change

Repeat steps 2–9 for every Domino host object. The change is not live until **Deploy** completes.

### 4. Verify

```bash
# Should return 'Domino Server is running (notes)' or similar — not a password prompt
sudo -u nagios sudo domino status
```

## Plugin Installation

```bash
cp check_domino_mail.sh /usr/lib/nagios/plugins/check_domino_mail
chmod +x /usr/lib/nagios/plugins/check_domino_mail
```

**Install on each Domino host.** The plugin runs local checks (`domino status`,
`domino cmd`, loopback network probes) and must execute on the host being monitored,
not the Icinga 2 master.

Verify from the agent user:

```bash
sudo -u nagios /usr/lib/nagios/plugins/check_domino_mail
```

## Method 1: Config File Deployment

### CheckCommand Definition

```bash
cp icinga2/checkcommand.conf /etc/icinga2/conf.d/check_domino_mail_command.conf
```

See [icinga2/checkcommand.conf](icinga2/checkcommand.conf) for full contents.

### Host Template

```bash
cp icinga2/host_template.conf /etc/icinga2/conf.d/check_domino_mail_host_template.conf
```

See [icinga2/host_template.conf](icinga2/host_template.conf) for full contents.

### Service Definition

```bash
cp icinga2/service.conf /etc/icinga2/conf.d/check_domino_mail_service.conf
```

See [icinga2/service.conf](icinga2/service.conf) for full contents.
Adjust the `assign where` rule to match your environment before deploying.

On each Domino host object, enable the check:

```icinga2
vars.check_domino_mail = true
```

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
   Name:        check_domino_mail
   Command:     $USER1$/check_domino_mail
   Description: Checks HCL Domino mail server health (7 sub-checks)
   ```

4. Switch to **Arguments** tab and add:

   | Argument | Value | Set if | Description |
   |----------|-------|--------|-------------|
   | `-H` | `$check_domino_mail_host$` | | Host/IP to probe |
   | `--nrpc-port` | `$check_domino_mail_nrpc_port$` | | NRPC port |
   | `--smtp-port` | `$check_domino_mail_smtp_port$` | | SMTP port |
   | `--http-url` | `$check_domino_mail_http_url$` | | HTTP URL to probe |
   | `--http-expect` | `$check_domino_mail_http_expect$` | | Expected body substring |
   | `-t` | `$check_domino_mail_timeout$` | | Network probe timeout |
   | `--handshake-timeout` | `$check_domino_mail_handshake_timeout$` | | NRPC handshake timeout |
   | `--domino-cmd` | `$check_domino_mail_domino_cmd$` | | Path to domino command |
   | `--cmd-timeout` | `$check_domino_mail_cmd_timeout$` | | domino cmd timeout |
   | `--no-status` | | `$check_domino_mail_no_status$` | Disable status sub-check |
   | `--no-nrpc-tcp` | | `$check_domino_mail_no_nrpc_tcp$` | Disable NRPC TCP sub-check |
   | `--no-nrpc-handshake` | | `$check_domino_mail_no_nrpc_handshake$` | Disable NRPC handshake |
   | `--no-show-server` | | `$check_domino_mail_no_show_server$` | Disable show server |
   | `--no-nrpc-trace` | | `$check_domino_mail_no_nrpc_trace$` | Disable NRPC trace |
   | `--no-smtp` | | `$check_domino_mail_no_smtp$` | Disable SMTP sub-check |
   | `--no-http` | | `$check_domino_mail_no_http$` | Disable HTTP sub-check |

5. Click **Store** then **Deploy**

### Create Host Template

1. Navigate to **Icinga Director > Hosts > Host Templates**
2. Click **+ Add**
3. Fill in:

   ```
   Name:          domino-mail-host
   Check command: hostalive
   ```

4. Switch to **Custom Properties** tab and add:

   ```
   check_domino_mail                   = true
   check_domino_mail_timeout           = 10
   check_domino_mail_handshake_timeout = 5
   check_domino_mail_cmd_timeout       = 20
   ```

5. Click **Store**

### Create Service

1. Navigate to **Icinga Director > Services > Apply Rules**
2. Click **+ Add**
3. Fill in:

   ```
   Name:          check_domino_mail
   Check command: check_domino_mail
   ```

4. Leave all Custom Properties blank at the service level — they are inherited from
   the host object or CheckCommand defaults.

5. Switch to **Assign** tab and add rule:
   - `host.vars.check_domino_mail` is `true`
   - or: `host.templates` contains `domino-mail-host`

6. Click **Store** then **Deploy**

Always trigger a **Deploy** after changes in Director. Changes are not active until deployed.

## Host-Specific Overrides

Set these on individual host objects to override defaults:

```icinga2
// Required on all hosts: run domino via sudo (see Prerequisites section)
vars.check_domino_mail_domino_cmd = "sudo domino"

// Override HTTP URL when no catch-all Web Site document exists in names.nsf
vars.check_domino_mail_http_url = "http://mail01.example.com/names.nsf?OpenDatabase"

// Disable SMTP check on a relay-only host
vars.check_domino_mail_no_smtp = true
```

In Director, set these on the host object under **Custom Properties**.

## Verification

```bash
# Full check (all sub-checks)
sudo -u nagios /usr/lib/nagios/plugins/check_domino_mail

# Quick connectivity test with reduced checks
sudo -u nagios /usr/lib/nagios/plugins/check_domino_mail --no-show-server --no-nrpc-trace

# Check a specific sub-check only
sudo -u nagios /usr/lib/nagios/plugins/check_domino_mail \
  --no-status --no-nrpc-tcp --no-nrpc-handshake \
  --no-show-server --no-nrpc-trace --no-http
```

Expected output (healthy):

```
check_domino_mail OK - status=OK nrpc_tcp=OK nrpc_handshake=OK show_server=OK nrpc_trace=OK smtp=OK http=OK | ...
```

```bash
icinga2 object list --type Service --name "check_domino_mail"
journalctl -u icinga2 -f
```
