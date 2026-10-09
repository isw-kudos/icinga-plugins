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
- An LDAP search client: the SDS-bundled `idsldapsearch` or OpenLDAP `ldapsearch`.
  Both are fully supported — the plugin auto-detects the flag syntax and
  auto-locates `idsldapsearch` under `/opt/*/ldap/*/bin`, so the icinga user does
  **not** need the SDS `bin` on its `PATH` (override with `--ldapsearch-bin` if your
  install lives elsewhere). OpenLDAP `ldapsearch` (`openldap-clients`) also works.
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
cp check_isds_monitor.sh /usr/lib64/nagios/plugins/check_isds_monitor
chmod +x /usr/lib64/nagios/plugins/check_isds_monitor
```

> **Plugin path:** these examples use the AlmaLinux 9 path `/usr/lib64/nagios/plugins`
> (the 64-bit RHEL-family `PluginDir`). On Debian/Ubuntu it is `/usr/lib/nagios/plugins`
> — confirm your distribution's `PluginDir` constant and adjust the paths accordingly.

Install on the node executing the check (typically the Icinga agent on, or near,
the SDS host) — not necessarily the Icinga 2 master.

## Method 1: Config File Deployment

> **Deploying several ISDS checks?** Use the ISDS service set in
> [servicesets/isds](../../../servicesets/isds/README.md) instead of the
> per-plugin `service.conf` files. It ships one host template and all four
> apply rules. Deploy one or the other, never both: they define services of
> the same names.

### CheckCommand Definition
```
cp icinga2/checkcommand.conf /etc/icinga2/conf.d/check_isds_monitor_command.conf
```

### Service Template
```
cp icinga2/service_template.conf /etc/icinga2/conf.d/check_isds_monitor_service_template.conf
```

The template sets the check interval and `command_endpoint = host.name`. The
check runs on the agent on the SDS host, because the IBM LDAP client and the bind password file exist only there.

### Service Definition
```
cp icinga2/service.conf /etc/icinga2/conf.d/check_isds_monitor_service.conf
```

Set the `isds` flag and the shared LDAP connection on the SDS host object, e.g.:
```
object Host "ldap01.example.com" {
  import "generic-host"
  address = "10.0.0.10"
  vars.isds = true
  vars.isds_ldap_host     = "127.0.0.1"
  vars.isds_ldap_binddn   = "cn=icinga-monitor,cn=Users,cn=ServiceAccounts,dc=example,dc=com"
  vars.isds_ldap_passfile = "/etc/icinga2/secrets/isds_monitor.pw"
}
```

Bind as a real service-account entry. `cn=monitor` is the search base, not an
entry you can bind as, and binding to it fails with LDAP rc=48
(*inappropriateAuthentication*). The `isds_ldap_*` variables are shared with
the other LDAP check in the ISDS set, so one account and one password file
serve both.

Validate and reload:
```
icinga2 daemon --validate
systemctl reload icinga2
```

## Method 2: Icinga Director (UI)

Assumes Icinga Director >= 1.10.0 with the Kickstart wizard completed.

### Create CheckCommand
1. Director > Commands > External Commands > **+ Add**
2. Name: `check_isds_monitor`, Command: `/usr/lib64/nagios/plugins/check_isds_monitor`
   Enter the command as an absolute path. Director prepends the plugin
   directory to the first word of the command unless it is already absolute,
   so `$USER1$/check_isds_monitor` becomes a doubled path that cannot run.
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
   | --ldapsearch-bin | `$isds_monitor_ldapsearch_bin$` | String | No     | No         | —                         | Absolute path to idsldapsearch/ldapsearch (auto-detected if unset) |
   | --ldap-flavor   | `$isds_monitor_ldap_flavor$`  | String  | No       | No         | —                         | Force ibm or openldap flag syntax (auto-detected if unset) |
   | --key-file      | `$isds_monitor_key_file$`     | String  | No       | No         | —                         | IBM SSL key database (.kdb) for --ldaps    |
   | --key-pw        | `$isds_monitor_key_pw$`       | String  | No       | No         | —                         | IBM SSL key database password/stash for --ldaps |
   | --monitor-base  | `$isds_monitor_base$`         | String  | No       | No         | —                         | Monitor search base (default cn=monitor)   |
   | --workers-warn  | `$isds_monitor_workers_warn$` | Number  | No       | No         | —                         | Warn when available workers <= N           |
   | --workers-crit  | `$isds_monitor_workers_crit$` | Number  | No       | No         | —                         | Crit when available workers <= N           |
   | --conn-warn     | `$isds_monitor_conn_warn$`    | Number  | No       | No         | —                         | Warn when current connections >= N         |
   | --conn-crit     | `$isds_monitor_conn_crit$`    | Number  | No       | No         | —                         | Crit when current connections >= N         |
   | --cache-warn    | `$isds_monitor_cache_warn$`   | Number  | No       | No         | —                         | Warn when a cache hit ratio < PCT%         |
   | --cache-crit    | `$isds_monitor_cache_crit$`   | Number  | No       | No         | —                         | Crit when a cache hit ratio < PCT%         |
   | -t              | `$isds_monitor_timeout$`      | Number  | No       | No         | —                         | Timeout in seconds (default 30)            |

4. **Store**, then **Deploy**.

### Create Service Template
1. Director > Services > Service Templates > **+ Add**
2. Name: `isds-monitor`, Check command: `check_isds_monitor`
3. Check interval `1m`, Retry interval `30s`, Max check attempts `3`
4. **Run on agent**: Yes
5. **Store**

### Create Service
1. Director > Services > Apply Rules > **+ Add**
2. Name: `isds-monitor`, Imports: `isds-monitor` (the template above)
3. Custom Properties: map the shared host variables onto the command's own,
   which otherwise default to `$address$` and port 389:

   | Custom property | Value |
   |-----------------|-------|
   | `isds_monitor_host` | `$isds_ldap_host$` |
   | `isds_monitor_port` | `$isds_ldap_port$` |
   | `isds_monitor_binddn` | `$isds_ldap_binddn$` |
   | `isds_monitor_passfile` | `$isds_ldap_passfile$` |

4. Assign tab: `host.vars.isds` is true
5. **Store**, then **Deploy**.

On the host (or a host template), set `isds = true` and the `isds_ldap_host`,
`isds_ldap_port`, `isds_ldap_binddn` and `isds_ldap_passfile` custom variables.

Sensitive values (the bind password): do not hardcode as a default var. Set the
password file path per host and keep the file root/icinga-readable only. In
Director use a Data Field and a secrets-store integration.

## Verification

```
sudo -u icinga /usr/lib64/nagios/plugins/check_isds_monitor -H 127.0.0.1 \
  -D "cn=icinga-monitor,cn=Users,cn=ServiceAccounts,dc=example,dc=com" \
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
