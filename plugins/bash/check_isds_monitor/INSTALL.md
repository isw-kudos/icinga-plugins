# Installation Guide: check_isds_monitor

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
- A bind account permitted to read `cn=monitor`

### Monitor account
Create a dedicated, least-privilege account that can read `cn=monitor` — do not
reuse an administrative DN. See **Creating the monitor bind account** in
[README.md](README.md) for the full LDIF / `idsldapadd` process. Store its
password in a root-owned file readable only by the Icinga user, e.g.:

```
install -o icinga -g icinga -m 0400 /dev/null /etc/icinga2/secrets/isds_monitor.pw
printf '%s' 'THE_PASSWORD' > /etc/icinga2/secrets/isds_monitor.pw
```

## Plugin Installation

```
cp check_isds_monitor.sh /usr/lib/nagios/plugins/check_isds_monitor
chmod +x /usr/lib/nagios/plugins/check_isds_monitor
```

Install on the node executing the check (typically the Icinga agent on, or near,
the SDS host) — not necessarily the Icinga 2 master.

## Method 1: Config File Deployment

### CheckCommand Definition
```
cp icinga2/checkcommand.conf /etc/icinga2/conf.d/check_isds_monitor_command.conf
```

### Service Definition
```
cp icinga2/service.conf /etc/icinga2/conf.d/check_isds_monitor_service.conf
```

Set the bind DN, password file and `isds` flag on the SDS host object, e.g.:
```
object Host "ldap01.example.com" {
  import "generic-host"
  address = "10.0.0.10"
  vars.isds = true
  vars.isds_monitor_binddn   = "cn=monitor"
  vars.isds_monitor_passfile = "/etc/icinga2/secrets/isds_monitor.pw"
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
2. Name: `check_isds_monitor`, Command: `$USER1$/check_isds_monitor`
3. Arguments tab — add each argument below. *Type* is the Director value type,
   *Required* mirrors the CheckCommand, *Repeat key* (`repeat_key`) applies to
   array arguments, and *Skip key* shows the `set_if` boolean that gates a flag
   argument (boolean flags carry no value — set them only via their `set_if` var):

   | Argument        | Value                         | Type    | Required | Repeat key | Skip key (set_if)         | Description                                |
   |-----------------|-------------------------------|---------|----------|------------|---------------------------|--------------------------------------------|
   | -H              | `$isds_monitor_host$`         | String  | No       | No         | —                         | LDAP host/IP (default 127.0.0.1)           |
   | -p              | `$isds_monitor_port$`         | Number  | No       | No         | —                         | LDAP port (default 389)                    |
   | --ldaps         | (none)                        | Boolean | No       | No         | `$isds_monitor_ldaps$`    | Use ldaps://                               |
   | -Z              | (none)                        | Boolean | No       | No         | `$isds_monitor_starttls$` | Use StartTLS on the plain port             |
   | -D              | `$isds_monitor_binddn$`       | String  | No       | No         | —                         | Bind DN (read-only monitor account)        |
   | -y              | `$isds_monitor_passfile$`     | String  | No       | No         | —                         | File containing the bind password          |
   | --monitor-base  | `$isds_monitor_base$`         | String  | No       | No         | —                         | Monitor search base (default cn=monitor)   |
   | --workers-warn  | `$isds_monitor_workers_warn$` | Number  | No       | No         | —                         | Warn when available workers <= N           |
   | --workers-crit  | `$isds_monitor_workers_crit$` | Number  | No       | No         | —                         | Crit when available workers <= N           |
   | --conn-warn     | `$isds_monitor_conn_warn$`    | Number  | No       | No         | —                         | Warn when current connections >= N         |
   | --conn-crit     | `$isds_monitor_conn_crit$`    | Number  | No       | No         | —                         | Crit when current connections >= N         |
   | --cache-warn    | `$isds_monitor_cache_warn$`   | Number  | No       | No         | —                         | Warn when a cache hit ratio < PCT%         |
   | --cache-crit    | `$isds_monitor_cache_crit$`   | Number  | No       | No         | —                         | Crit when a cache hit ratio < PCT%         |
   | -t              | `$isds_monitor_timeout$`      | Number  | No       | No         | —                         | Timeout in seconds (default 30)            |

4. **Store**, then **Deploy**.

### Create Service
1. Director > Services > Apply Rules > **+ Add**
2. Name: `isds-monitor`, Check command: `check_isds_monitor`
3. Custom Properties: set `isds_monitor_binddn`, `isds_monitor_passfile`
4. Assign tab: `host.vars.isds` is true
5. **Store**, then **Deploy**.

Sensitive values (the bind password): do not hardcode as a default var. Set the
password file path per host and keep the file root/icinga-readable only. In
Director use a Data Field and a secrets-store integration.

## Verification

```
/usr/lib/nagios/plugins/check_isds_monitor -H 127.0.0.1 -D cn=monitor \
  -y /etc/icinga2/secrets/isds_monitor.pw
```

Expected (healthy server):
```
check_isds_monitor OK - workers=OK connections=OK throughput=OK cache=OK | ...
```

If a sub-check returns `UNKNOWN - Attribute '...' not found`, the `cn=monitor`
attribute names differ on your SDS version — adjust them in the *Attribute names*
block at the top of the script and re-run.

```
icinga2 object list --type Service --name "isds-monitor"
journalctl -u icinga2 -f
```
