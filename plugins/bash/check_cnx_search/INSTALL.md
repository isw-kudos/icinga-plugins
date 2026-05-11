# Installation Guide: check_cnx_search

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
- Bash >= 4.x
- `curl`
- `xmllint` — install via:
  - Debian/Ubuntu: `apt install libxml2-utils`
  - RHEL/Rocky: `yum install libxml2`
- GNU `date` (Linux only — not compatible with macOS/BSD)
- HCL Connections with search enabled and reachable from the Icinga node

## Plugin Installation

```bash
cp check_cnx_search.sh /usr/lib/nagios/plugins/check_cnx_search
chmod +x /usr/lib/nagios/plugins/check_cnx_search
```

If using a satellite/agent setup, install the plugin on the node executing the check,
not necessarily the Icinga 2 master.

## Method 1: Config File Deployment

### CheckCommand Definition

```bash
cp icinga2/checkcommand.conf /etc/icinga2/conf.d/check_cnx_search_command.conf
```

See [icinga2/checkcommand.conf](icinga2/checkcommand.conf) for full contents.

### Host Template

```bash
cp icinga2/host_template.conf /etc/icinga2/conf.d/check_cnx_search_host_template.conf
```

See [icinga2/host_template.conf](icinga2/host_template.conf) for full contents.

### Service Definition

```bash
cp icinga2/service.conf /etc/icinga2/conf.d/check_cnx_search_service.conf
```

See [icinga2/service.conf](icinga2/service.conf) for full contents.
Adjust the `assign where` rule to match your environment before deploying.

On each HCL Connections host object, set the required vars:

```icinga2
vars.check_cnx_search          = true
vars.check_cnx_search_url      = "https://connections.example.com"
vars.check_cnx_search_username = "icinga_monitor"
vars.check_cnx_search_password = "secret"
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
   Name:        check_cnx_search
   Command:     $USER1$/check_cnx_search
   Description: Checks HCL Connections search index freshness
   ```

4. Switch to **Arguments** tab and add:

   | Argument | Value                         | Required | Description                    |
   |----------|-------------------------------|----------|--------------------------------|
   | `-H`     | `$check_cnx_search_url$`      | Yes      | HCL Connections base URL       |
   | `-u`     | `$check_cnx_search_username$` | Yes      | Username for authentication    |
   | `-p`     | `$check_cnx_search_password$` | Yes      | Password for authentication    |
   | `-w`     | `$check_cnx_search_warning$`  | No       | Warning threshold in hours     |
   | `-c`     | `$check_cnx_search_critical$` | No       | Critical threshold in hours    |
   | `-t`     | `$check_cnx_search_timeout$`  | No       | Timeout in seconds             |

5. Click **Store** then **Deploy**

### Create Host Template

1. Navigate to **Icinga Director > Hosts > Host Templates**
2. Click **+ Add**
3. Fill in:

   ```
   Name:          hcl-connections-host
   Check command: hostalive
   ```

4. Switch to **Custom Properties** tab and add:

   ```
   check_cnx_search          = true
   check_cnx_search_warning  = 20
   check_cnx_search_critical = 24
   ```

5. Click **Store**

### Create Service

1. Navigate to **Icinga Director > Services > Apply Rules**
2. Click **+ Add**
3. Fill in:

   ```
   Name:          check_cnx_search
   Check command: check_cnx_search
   ```

4. Switch to **Custom Properties** tab and add:

   ```
   check_cnx_search_url      = (leave blank — set per host)
   check_cnx_search_username = (leave blank — set per host)
   check_cnx_search_password = (leave blank — set per host)
   check_cnx_search_warning  = 20
   check_cnx_search_critical = 24
   ```

5. Switch to **Assign** tab and add rule:
   - `host.vars.check_cnx_search` is `true`
   - or: `host.templates` contains `hcl-connections-host`

6. Click **Store** then **Deploy**

Always trigger a **Deploy** after changes in Director. Changes are not active until deployed.

**Sensitive values** (username, password): Do not hardcode as default vars. Set at host
level or use Icinga 2 constants. In Director, use Data Fields with type String and
advise use of a secrets store integration.

## Verification

```bash
/usr/lib/nagios/plugins/check_cnx_search \
  -H https://connections.example.com \
  -u icinga_monitor \
  -p secret \
  -w 20 \
  -c 24
```

Expected output:

```
check_cnx_search OK - Search index is fresh - last updated 2h 15m ago | age=8100s;72000;86400;0
```

```bash
icinga2 object list --type Service --name "check_cnx_search"
journalctl -u icinga2 -f
```
