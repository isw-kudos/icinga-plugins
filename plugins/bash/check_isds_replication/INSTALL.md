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
cp check_isds_replication.sh /usr/lib/nagios/plugins/check_isds_replication
chmod +x /usr/lib/nagios/plugins/check_isds_replication
```

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
3. Arguments tab — add (Value column shown):

   | Argument    | Value                       |
   |-------------|-----------------------------|
   | -H          | `$isds_repl_host$`          |
   | -p          | `$isds_repl_port$`          |
   | -D          | `$isds_repl_binddn$`        |
   | -y          | `$isds_repl_passfile$`      |
   | -b          | `$isds_repl_base$`          |
   | --repl-base | `$isds_repl_repl_base$`     |
   | -w          | `$isds_repl_pending_warn$`  |
   | -c          | `$isds_repl_pending_crit$`  |
   | --lag-warn  | `$isds_repl_lag_warn$`      |
   | --lag-crit  | `$isds_repl_lag_crit$`      |
   | -t          | `$isds_repl_timeout$`       |

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
/usr/lib/nagios/plugins/check_isds_replication -H 127.0.0.1 -D cn=monitor \
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
