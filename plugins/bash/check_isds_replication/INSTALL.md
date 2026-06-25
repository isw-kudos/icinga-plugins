# Installation Guide: check_isds_replication

## Table of Contents
- Requirements
- Plugin Installation
- Method 1: Config File Deployment
- Method 2: Icinga Director (UI)
- Verification

## Requirements
- Icinga 2 >= 2.13.0
- Bash >= 4.x
- An LDAP search client in `PATH` on the executing node: the SDS-bundled
  `idsldapsearch` (preferred) or a standard `ldapsearch`
- A bind account permitted to read the replication agreement entries

### Monitor account
Create a dedicated, least-privilege account that can read the replication
agreement entries under your suffix. Do not reuse an administrative DN. Store its
password in a root-owned file readable only by the Icinga user, e.g.:

```
install -o icinga -g icinga -m 0400 /dev/null /etc/icinga2/secrets/isds_repl.pw
printf '%s' 'THE_PASSWORD' > /etc/icinga2/secrets/isds_repl.pw
```

## Plugin Installation

```
cp check_isds_replication.sh /usr/lib64/nagios/plugins/check_isds_replication
chmod +x /usr/lib64/nagios/plugins/check_isds_replication
```

> **Plugin path:** these examples use the AlmaLinux 9 path `/usr/lib64/nagios/plugins`
> (the 64-bit RHEL-family `PluginDir`). On Debian/Ubuntu it is `/usr/lib/nagios/plugins`
> — confirm your distribution's `PluginDir` constant and adjust the paths accordingly.

Install on the node executing the check (typically the Icinga agent on, or near,
the SDS host) — not necessarily the Icinga 2 master.

## Method 1: Config File Deployment

### CheckCommand Definition
```
cp icinga2/checkcommand.conf /etc/icinga2/conf.d/check_isds_replication_command.conf
```

### Service Definition
```
cp icinga2/service.conf /etc/icinga2/conf.d/check_isds_replication_service.conf
```

Set the bind DN, password file, the replication search base and the `isds` flag
on the SDS host object, e.g.:
```
object Host "ldap01.example.com" {
  import "generic-host"
  address = "10.0.0.10"
  vars.isds = true
  vars.isds_repl_binddn   = "cn=monitor"
  vars.isds_repl_passfile = "/etc/icinga2/secrets/isds_repl.pw"
  vars.isds_repl_base     = "dc=example,dc=com"
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
2. Name: `check_isds_replication`, Command: `$USER1$/check_isds_replication`
3. Arguments tab — add each argument below. *Type* is the Director value type,
   *Required* mirrors the CheckCommand, *Repeat key* (`repeat_key`) applies to
   array arguments, and *Skip key* shows the `set_if` boolean that gates a flag
   argument (boolean flags carry no value — set them only via their `set_if` var):

   | Argument    | Value                       | Type    | Required | Repeat key | Skip key (set_if)      | Description                                  |
   |-------------|-----------------------------|---------|----------|------------|------------------------|----------------------------------------------|
   | -H          | `$isds_repl_host$`          | String  | No       | No         | —                      | LDAP host/IP (default 127.0.0.1)             |
   | -p          | `$isds_repl_port$`          | Number  | No       | No         | —                      | LDAP port (default 389)                      |
   | --ldaps     | (none)                      | Boolean | No       | No         | `$isds_repl_ldaps$`    | Use ldaps://                                 |
   | -Z          | (none)                      | Boolean | No       | No         | `$isds_repl_starttls$` | Use StartTLS on the plain port               |
   | -D          | `$isds_repl_binddn$`        | String  | No       | No         | —                      | Bind DN (read-only replication account)      |
   | -y          | `$isds_repl_passfile$`      | String  | No       | No         | —                      | File containing the bind password            |
   | -b          | `$isds_repl_base$`          | String  | **Yes**  | No         | —                      | Search base for replication agreements       |
   | --repl-base | `$isds_repl_repl_base$`     | String  | No       | No         | —                      | Optional sub-tree under -b to search instead |
   | --agreement | `$isds_repl_agreement$`     | String  | No       | **Yes**    | —                      | Only check agreement(s) with this cn (array) |
   | -w          | `$isds_repl_pending_warn$`  | Number  | No       | No         | —                      | Warn when pending changes >= N               |
   | -c          | `$isds_repl_pending_crit$`  | Number  | No       | No         | —                      | Crit when pending changes >= N               |
   | --lag-warn  | `$isds_repl_lag_warn$`      | Number  | No       | No         | —                      | Warn when last-change age >= seconds         |
   | --lag-crit  | `$isds_repl_lag_crit$`      | Number  | No       | No         | —                      | Crit when last-change age >= seconds         |
   | -t          | `$isds_repl_timeout$`       | Number  | No       | No         | —                      | Timeout in seconds (default 30)              |

4. **Store**, then **Deploy**.

### Create Service
1. Director > Services > Apply Rules > **+ Add**
2. Name: `isds-replication`, Check command: `check_isds_replication`
3. Custom Properties: set `isds_repl_binddn`, `isds_repl_passfile`, `isds_repl_base`
4. Assign tab: `host.vars.isds` is true
5. **Store**, then **Deploy**.

Sensitive values (the bind password): do not hardcode as a default var. Set the
password file path per host and keep the file root/icinga-readable only. In
Director use a Data Field and a secrets-store integration.

## Verification

```
/usr/lib64/nagios/plugins/check_isds_replication -H 127.0.0.1 -D cn=monitor \
  -y /etc/icinga2/secrets/isds_repl.pw -b "dc=example,dc=com"
```

Expected (healthy server):
```
check_isds_replication OK - <agreement>=OK ... | agreements_ok=N agreements_error=0 ...
```

If the plugin returns `UNKNOWN - no replication agreements found under ...`, check
the `-b`/`--repl-base` value and the bind account's read access to the agreement
entries. If a status attribute looks wrong for your SDS version, adjust the
*Attribute names* block at the top of the script and re-run.

```
icinga2 object list --type Service --name "isds-replication"
journalctl -u icinga2 -f
```
