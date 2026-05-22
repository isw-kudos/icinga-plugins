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
  - Configure Each Host Object
- Host-Specific Overrides
- Verification

## Requirements

- Icinga 2 >= 2.13.0
- Bash >= 4.x
- HCL Domino >= 14.0 on Linux
- Nashcom Domino start script — `domino` command in PATH
- `python3` (for NRPC handshake probe)
- `curl` (for HTTP probe)
- Icinga 2 agent installed and running on each Domino host

## Prerequisites on the Domino Host

### 1. Nashcom start script

The `domino` command must be installed and locatable. Find its path:

```bash
which domino
# common locations: /bin/domino  /usr/bin/domino  /opt/nashcom/domino/domino
```

### 2. Sudoers entry (required)

The Nashcom start script uses `su` to switch to the `notes` user internally.
When invoked by the Icinga agent user (`nagios` on RHEL, `icinga` on Debian/Ubuntu),
this fails with `su: Authentication failure`. Allow the agent user to call `domino`
via `sudo` by creating `/etc/sudoers.d/icinga-domino`:

```
# RHEL / Rocky Linux
nagios ALL=(ALL) NOPASSWD: /bin/domino

# Debian / Ubuntu
icinga ALL=(ALL) NOPASSWD: /usr/bin/domino
```

Replace the path with the output of `which domino` on your system.

### 3. Verify

```bash
# RHEL — should print 'Domino Server is running (notes)', not a password prompt
sudo -u nagios sudo /bin/domino status

# Debian / Ubuntu
sudo -u icinga sudo /usr/bin/domino status
```

## Plugin Installation

The plugin must run on the Domino host itself (it probes loopback ports and invokes
`domino cmd` locally). Install it on every Domino host, not on the Icinga master.

```bash
# RHEL / Rocky Linux
cp check_domino_mail.sh /usr/lib64/nagios/plugins/check_domino_mail
chmod +x /usr/lib64/nagios/plugins/check_domino_mail

# Debian / Ubuntu
cp check_domino_mail.sh /usr/lib/nagios/plugins/check_domino_mail
chmod +x /usr/lib/nagios/plugins/check_domino_mail
```

Verify from the agent user, passing `--domino-cmd` to match the sudoers entry:

```bash
# RHEL
sudo -u nagios /usr/lib64/nagios/plugins/check_domino_mail \
  --domino-cmd "sudo /bin/domino"

# Debian / Ubuntu
sudo -u icinga /usr/lib/nagios/plugins/check_domino_mail \
  --domino-cmd "sudo /usr/bin/domino"
```

Expected output when Domino is healthy (smtp/http may still show CRIT if those
tasks are restricted — see Known Issues in README.md):

```
check_domino_mail OK - status=OK nrpc_tcp=OK nrpc_handshake=OK show_server=OK nrpc_trace=OK smtp=OK http=OK | ...
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

On each Domino host object, enable the check and set the domino command:

```icinga2
vars.check_domino_mail          = true
vars.check_domino_mail_domino_cmd = "sudo /bin/domino"   // adjust path to match which domino
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
   | `-H` | `$check_domino_mail_host$` | | Host/IP to probe (default: 127.0.0.1) |
   | `--nrpc-port` | `$check_domino_mail_nrpc_port$` | | NRPC port (default: 1352) |
   | `--smtp-port` | `$check_domino_mail_smtp_port$` | | SMTP port (default: 25) |
   | `--http-url` | `$check_domino_mail_http_url$` | | HTTP URL to probe |
   | `--http-expect` | `$check_domino_mail_http_expect$` | | Expected body substring |
   | `-t` | `$check_domino_mail_timeout$` | | Network probe timeout (default: 10) |
   | `--handshake-timeout` | `$check_domino_mail_handshake_timeout$` | | NRPC handshake timeout (default: 5) |
   | `--domino-cmd` | `$check_domino_mail_domino_cmd$` | | Command to invoke domino |
   | `--cmd-timeout` | `$check_domino_mail_cmd_timeout$` | | domino cmd timeout (default: 20) |
   | `--no-status` | | `$check_domino_mail_no_status$` | Disable status sub-check |
   | `--no-nrpc-tcp` | | `$check_domino_mail_no_nrpc_tcp$` | Disable NRPC TCP sub-check |
   | `--no-nrpc-handshake` | | `$check_domino_mail_no_nrpc_handshake$` | Disable NRPC handshake |
   | `--no-show-server` | | `$check_domino_mail_no_show_server$` | Disable show server |
   | `--no-nrpc-trace` | | `$check_domino_mail_no_nrpc_trace$` | Disable NRPC trace |
   | `--no-smtp` | | `$check_domino_mail_no_smtp$` | Disable SMTP sub-check |
   | `--no-http` | | `$check_domino_mail_no_http$` | Disable HTTP sub-check |

   **Important:** Every row in the left column has either a **Value** (string variable) OR a
   **Set if** (boolean variable) — never both on the same row. The first nine rows use Value;
   the last seven use Set if.

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

   Do **not** add `check_domino_mail_host` or `check_domino_mail_domino_cmd` to the
   template — these must be set per host object (see next section).

5. Click **Store**

### Create Service

1. Navigate to **Icinga Director > Services > Apply Rules**
2. Click **+ Add**
3. Fill in:

   ```
   Name:          check_domino_mail
   Check command: check_domino_mail
   ```

4. Switch to **Assign** tab and add rule:
   - `host.vars.check_domino_mail` is `true`
   - or: `host.templates` contains `domino-mail-host`

5. Click **Store** then **Deploy**

### Configure Each Host Object

Every Domino host object needs two settings. Without these the check will not work correctly.

**1. Set the domino command (required)**

1. Go to **Icinga Director > Hosts** and open the Domino host object
2. Click the **Custom Properties** tab
3. Add a property with:
   - **Name:** `check_domino_mail_domino_cmd`
   - **Value:** `sudo /bin/domino` ← adjust path to match `which domino`

   > **String field only.** Use the plain text Value field — not a toggle or Set if field.
   > If set as a boolean, Director passes the literal word `true` as the argument value,
   > which breaks the check.

4. Click **Store**

**2. Configure the command endpoint (required)**

The check must run on the Domino host's agent, not on the Icinga master.
Without this, domino commands run on the wrong machine.

1. On the same host object, click the **Agent** tab
2. Set **Check command endpoint** to the agent's node name
   (run `hostname -f` on the Domino host if unsure)
3. Click **Store**

**3. Deploy**

Always click **Deploy** after changes in Director. Changes are not active until deployed.

**What NOT to set:**

- Do **not** add `check_domino_mail_host` as a Custom Property.
  The plugin defaults to `127.0.0.1` automatically. If you accidentally add it as a
  boolean toggle, Director passes `-H true` to the plugin, which causes all network
  probes (NRPC, SMTP) to fail with "unreachable".

## Host-Specific Overrides

Set these on individual host objects under **Custom Properties**:

```icinga2
// Required on every host
vars.check_domino_mail_domino_cmd = "sudo /bin/domino"   // path from: which domino

// Override HTTP URL when no catch-all Web Site document exists in names.nsf
vars.check_domino_mail_http_url = "http://mail01.example.com/names.nsf?OpenDatabase"

// Disable SMTP check on a relay-only host
vars.check_domino_mail_no_smtp = true
```

## Verification

Run manually as the agent user with the same arguments Icinga will use:

```bash
# RHEL
sudo -u nagios /usr/lib64/nagios/plugins/check_domino_mail \
  --domino-cmd "sudo /bin/domino"

# Debian / Ubuntu
sudo -u icinga /usr/lib/nagios/plugins/check_domino_mail \
  --domino-cmd "sudo /usr/bin/domino"
```

All five core sub-checks should be OK. SMTP and HTTP may still report CRIT if those
Domino tasks are restricted — see Known Issues in README.md.

```bash
# Confirm the service object exists and is assigned correctly
icinga2 object list --type Service --name "check_domino_mail"

# Watch the agent log for check execution
journalctl -u icinga2 -f
```
