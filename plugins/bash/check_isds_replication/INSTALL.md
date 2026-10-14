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
- An LDAP search client: the SDS-bundled `idsldapsearch` or OpenLDAP `ldapsearch`.
  Both are fully supported — the plugin auto-detects the flag syntax and
  auto-locates `idsldapsearch` under `/opt/*/ldap/*/bin`, so the icinga user does
  **not** need the SDS `bin` on its `PATH` (override with `--ldapsearch-bin` if your
  install lives elsewhere). OpenLDAP `ldapsearch` (`openldap-clients`) also works.
- A bind account permitted to read the replication agreement entries

### Monitor account
Create a dedicated, least-privilege account that can read the replication
agreement entries under your suffix. Do not reuse an administrative DN. The
account and password file created for `check_isds_monitor` serve both checks.
See **Creating the monitor bind account** in
[check_isds_monitor/README.md](../check_isds_monitor/README.md#creating-the-monitor-bind-account).
Store the password in a file readable only by the Icinga user, e.g.:

```
install -o icinga -g icinga -m 0400 /dev/null /etc/icinga2/secrets/isds_monitor.pw
printf '%s' 'THE_PASSWORD' > /etc/icinga2/secrets/isds_monitor.pw
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

> **Deploying several ISDS checks?** Use the ISDS service set in
> [servicesets/isds](../../../servicesets/isds/README.md) instead of the
> per-plugin `service.conf` files. It ships one host template and all four
> apply rules. Deploy one or the other, never both: they define services of
> the same names.

### CheckCommand Definition
```
cp icinga2/checkcommand.conf /etc/icinga2/conf.d/check_isds_replication_command.conf
```

### Service Template
```
cp icinga2/service_template.conf /etc/icinga2/conf.d/check_isds_replication_service_template.conf
```

The template sets the check interval and `command_endpoint = host.name`. The
check runs on the agent on the SDS host, because the IBM LDAP client and the bind password file exist only there.

### Service Definition
```
cp icinga2/service.conf /etc/icinga2/conf.d/check_isds_replication_service.conf
```

Set the `isds` flag, the shared LDAP connection and the replication search base
on the SDS host object, e.g.:
```
object Host "ldap01.example.com" {
  import "generic-host"
  address = "10.0.0.10"
  vars.isds = true
  vars.isds_ldap_host     = "127.0.0.1"
  vars.isds_ldap_binddn   = "cn=icinga-monitor,cn=Users,cn=ServiceAccounts,dc=example,dc=com"
  vars.isds_ldap_passfile = "/etc/icinga2/secrets/isds_monitor.pw"
  vars.isds_repl_base     = "dc=example,dc=com"
}
```

Bind as a real service-account entry. `cn=monitor` is the search base, not an
entry you can bind as, and binding to it fails with LDAP rc=48
(*inappropriateAuthentication*). The `isds_ldap_*` variables are shared with
the other LDAP check in the ISDS set, so one account and one password file
serve both.

Apply the service to **every** server in the replication topology. An
agreement's operational state is published only on its supplier side. On the
consumer side the check reports an informational OK, so in a peer pair
checking a single server sees only one direction.

Validate and reload:
```
icinga2 daemon --validate
systemctl reload icinga2
```

## Method 2: Icinga Director (UI)

Assumes Icinga Director >= 1.10.0 with the Kickstart wizard completed.

### Create CheckCommand
1. Director > Commands > External Commands > **+ Add**
2. Name: `check_isds_replication`, Command: `/usr/lib64/nagios/plugins/check_isds_replication`
   Enter the command as an absolute path. Director prepends the plugin
   directory to the first word of the command unless it is already absolute,
   so `$USER1$/check_isds_replication` becomes a doubled path that cannot run.
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
   | --ldapsearch-bin | `$isds_repl_ldapsearch_bin$` | String | No     | No         | —                      | Absolute path to idsldapsearch/ldapsearch (auto-detected if unset) |
   | --ldap-flavor | `$isds_repl_ldap_flavor$`  | String  | No       | No         | —                      | Force ibm or openldap flag syntax (auto-detected if unset) |
   | --key-file  | `$isds_repl_key_file$`      | String  | No       | No         | —                      | IBM SSL key database (.kdb) for --ldaps      |
   | --key-pw    | `$isds_repl_key_pw$`        | String  | No       | No         | —                      | IBM SSL key database password/stash for --ldaps |
   | -b          | `$isds_repl_base$`          | String  | **Yes**  | No         | —                      | Search base for replication agreements       |
   | --repl-base | `$isds_repl_repl_base$`     | String  | No       | No         | —                      | Optional sub-tree under -b to search instead |
   | --agreement | `$isds_repl_agreement$`     | String  | No       | **Yes**    | —                      | Only check agreement(s) with this cn (array) |
   | -w          | `$isds_repl_pending_warn$`  | Number  | No       | No         | —                      | Warn when pending changes >= N               |
   | -c          | `$isds_repl_pending_crit$`  | Number  | No       | No         | —                      | Crit when pending changes >= N               |
   | --lag-warn  | `$isds_repl_lag_warn$`      | Number  | No       | No         | —                      | Warn when last-change age >= seconds         |
   | --lag-crit  | `$isds_repl_lag_crit$`      | Number  | No       | No         | —                      | Crit when last-change age >= seconds         |
   | -t          | `$isds_repl_timeout$`       | Number  | No       | No         | —                      | Timeout in seconds (default 30)              |

4. **Store**, then **Deploy**.

### Create Service Template
1. Director > Services > Service Templates > **+ Add**
2. Name: `isds-replication`, Check command: `check_isds_replication`
3. Check interval `2m`, Retry interval `1m`, Max check attempts `3`
4. **Run on agent**: Yes
5. **Store**

### Create Service
1. Director > Services > Apply Rules > **+ Add**
2. Name: `isds-replication`, Imports: `isds-replication` (the template above)
3. Custom Properties: map the shared host variables onto the command's own,
   which otherwise default to `$address$` and port 389:

   | Custom property | Value |
   |-----------------|-------|
   | `isds_repl_host` | `$isds_ldap_host$` |
   | `isds_repl_port` | `$isds_ldap_port$` |
   | `isds_repl_binddn` | `$isds_ldap_binddn$` |
   | `isds_repl_passfile` | `$isds_ldap_passfile$` |

   `isds_repl_base` needs no mapping. Set it on the host, and the service picks
   it up under the same name.

4. Assign tab: `host.vars.isds` is true
5. **Store**, then **Deploy**.

On the host (or a host template), set `isds = true`, `isds_repl_base`, and the
`isds_ldap_host`, `isds_ldap_port`, `isds_ldap_binddn` and `isds_ldap_passfile`
custom variables.

Sensitive values (the bind password): do not hardcode as a default var. Set the
password file path per host and keep the file root/icinga-readable only. In
Director use a Data Field and a secrets-store integration.

## Verification

```
sudo -u icinga /usr/lib64/nagios/plugins/check_isds_replication -H 127.0.0.1 \
  -D "cn=icinga-monitor,cn=Users,cn=ServiceAccounts,dc=example,dc=com" \
  -y /etc/icinga2/secrets/isds_monitor.pw -b "dc=example,dc=com"
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
