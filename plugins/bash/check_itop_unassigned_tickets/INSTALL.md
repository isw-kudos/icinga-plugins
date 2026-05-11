# Installation Guide: check_itop_unassigned_tickets

## Table of Contents

- Requirements
- iTop API Prerequisites
- Plugin Installation
- Method 1: Config File Deployment
  - CheckCommand Definition
  - Host Template
  - Service Definition
  - Multiple Ticket Classes
- Method 2: Icinga Director (UI)
  - Create CheckCommand
  - Create Host Template
  - Create Service
- Verification

## Requirements

- Icinga 2 >= 2.13.0
- Bash >= 4.x
- `curl`
- `python3` >= 3.6 (typically pre-installed)
- iTop >= 2.7 with REST API enabled
- iTop user with `REST Services User` profile

## iTop API Prerequisites

1. In iTop, navigate to **Administration > User Accounts**
2. Create or select a monitoring user
3. Assign the `REST Services User` profile
4. Confirm `/webservices/rest.php` is accessible from the Icinga node

## Plugin Installation

```bash
cp check_itop_unassigned_tickets.sh /usr/lib/nagios/plugins/check_itop_unassigned_tickets
chmod +x /usr/lib/nagios/plugins/check_itop_unassigned_tickets
```

If using a satellite/agent setup, install the plugin on the node executing the check,
not necessarily the Icinga 2 master.

## Method 1: Config File Deployment

### CheckCommand Definition

```bash
cp icinga2/checkcommand.conf /etc/icinga2/conf.d/check_itop_unassigned_tickets_command.conf
```

See [icinga2/checkcommand.conf](icinga2/checkcommand.conf) for full contents.

### Host Template

```bash
cp icinga2/host_template.conf /etc/icinga2/conf.d/check_itop_unassigned_tickets_host_template.conf
```

See [icinga2/host_template.conf](icinga2/host_template.conf) for full contents.

### Service Definition

```bash
cp icinga2/service.conf /etc/icinga2/conf.d/check_itop_unassigned_tickets_service.conf
```

See [icinga2/service.conf](icinga2/service.conf) for full contents.
Adjust the `assign where` rule to match your environment before deploying.

On each iTop host object, set the required vars:

```icinga2
vars.check_itop_unassigned_tickets          = true
vars.check_itop_unassigned_tickets_url      = "https://itop.example.com"
vars.check_itop_unassigned_tickets_username = "icinga_monitor"
vars.check_itop_unassigned_tickets_password = "secret"
```

Validate and reload Icinga 2:

```bash
icinga2 daemon --validate
systemctl reload icinga2
```

### Multiple Ticket Classes

To check more than one ticket class (e.g. both Incident and UserRequest), add a second
`apply Service` block to your service conf with a distinct name:

```icinga2
apply Service "check_itop_unassigned_UserRequest" {
  check_command = "check_itop_unassigned_tickets"

  vars.check_itop_unassigned_tickets_url      = host.vars.check_itop_unassigned_tickets_url
  vars.check_itop_unassigned_tickets_username = host.vars.check_itop_unassigned_tickets_username
  vars.check_itop_unassigned_tickets_password = host.vars.check_itop_unassigned_tickets_password
  vars.check_itop_unassigned_tickets_class    = "UserRequest"
  vars.check_itop_unassigned_tickets_warning  = 5
  vars.check_itop_unassigned_tickets_critical = 10

  assign where host.vars.check_itop_unassigned_tickets == true
}
```

## Method 2: Icinga Director (UI)

Assumes Icinga Director is installed and Kickstart wizard completed.
Minimum supported Director version: 1.10.0

### Create CheckCommand

1. Navigate to **Icinga Director > Commands > External Commands**
2. Click **+ Add**
3. Fill in:

   ```
   Name:        check_itop_unassigned_tickets
   Command:     $USER1$/check_itop_unassigned_tickets
   Description: Checks iTop for unassigned tickets
   ```

4. Switch to **Arguments** tab and add:

   | Argument | Value                                        | Required | Description                  |
   |----------|----------------------------------------------|----------|------------------------------|
   | `-H`     | `$check_itop_unassigned_tickets_url$`        | Yes      | iTop base URL                |
   | `-u`     | `$check_itop_unassigned_tickets_username$`   | Yes      | API username                 |
   | `-p`     | `$check_itop_unassigned_tickets_password$`   | Yes      | API password                 |
   | `-w`     | `$check_itop_unassigned_tickets_warning$`    | No       | Warning threshold            |
   | `-c`     | `$check_itop_unassigned_tickets_critical$`   | No       | Critical threshold           |
   | `-C`     | `$check_itop_unassigned_tickets_class$`      | No       | Ticket class                 |
   | `-t`     | `$check_itop_unassigned_tickets_timeout$`    | No       | Timeout in seconds           |

5. Click **Store** then **Deploy**

### Create Host Template

1. Navigate to **Icinga Director > Hosts > Host Templates**
2. Click **+ Add**
3. Fill in:

   ```
   Name:          itop-host
   Check command: hostalive
   ```

4. Switch to **Custom Properties** tab and add:

   ```
   check_itop_unassigned_tickets          = true
   check_itop_unassigned_tickets_warning  = 1
   check_itop_unassigned_tickets_critical = 2
   check_itop_unassigned_tickets_class    = Incident
   ```

5. Click **Store**

### Create Service

1. Navigate to **Icinga Director > Services > Apply Rules**
2. Click **+ Add**
3. Fill in:

   ```
   Name:          check_itop_unassigned_tickets
   Check command: check_itop_unassigned_tickets
   ```

4. Switch to **Custom Properties** tab:

   ```
   check_itop_unassigned_tickets_url      = (leave blank — set per host)
   check_itop_unassigned_tickets_username = (leave blank — set per host)
   check_itop_unassigned_tickets_password = (leave blank — set per host)
   check_itop_unassigned_tickets_warning  = 1
   check_itop_unassigned_tickets_critical = 2
   check_itop_unassigned_tickets_class    = Incident
   ```

5. Switch to **Assign** tab and add rule:
   - `host.vars.check_itop_unassigned_tickets` is `true`
   - or: `host.templates` contains `itop-host`

6. Click **Store** then **Deploy**

Always trigger a **Deploy** after changes in Director. Changes are not active until deployed.

**Sensitive values** (username, password): Do not hardcode as default vars. Set at host
level. In Director, use Data Fields with type String and advise use of a secrets store
integration.

## Verification

```bash
/usr/lib/nagios/plugins/check_itop_unassigned_tickets \
  -H https://itop.example.com \
  -u icinga_monitor \
  -p secret \
  -w 1 \
  -c 2 \
  -C Incident
```

Expected output:

```
check_itop_unassigned_tickets OK - 0 unassigned Incident ticket(s) | unassigned_tickets=0;1;2;0
```

```bash
icinga2 object list --type Service --name "check_itop_unassigned_tickets"
journalctl -u icinga2 -f
```
