# ISDS Service Set

Four checks for an IBM Security Directory Server / IBM Security Verify Directory
(ISDS / ISVD) instance, deployable as one unit.

A port check and an LDAP bind tell you the server is listening. They do not
tell you it is serving. A directory server can accept connections with an
exhausted worker pool, stop replicating to its peer while both sides stay up,
fill its DB2 backend, or reach the expiry date on its server certificate. A
port check stays green through all four.

## What is in the set

| # | Service | Check | Alerts on | Interval |
|---|---------|-------|-----------|----------|
| 1 | `isds-monitor` | `check_isds_monitor` | Worker pool exhausted, connection count; cache hit ratio opt-in | 1m |
| 2 | `isds-replication` | `check_isds_replication` | Agreement in error or on hold, pending-change backlog | 2m |
| 3 | `isds-backend` | `check_isds_backend` | ibmslapd / ibmdiradm / db2sysc down, DB2 tablespace or log full | 1m |
| 4 | `isds-cert` | `check_isds_cert` | Server certificate expiring (WARN 30d / CRIT 7d) | 6h |

All four run **on the agent on the SDS host** (`command_endpoint = host.name`).
The IBM LDAP client, the bind password file, the DB2 CLI and the keystore all
exist only there.

Nothing in the ITL or the standard plugins covers these checks. `check_ldap`
can test a bind, but it cannot read `cn=monitor`, replication agreements, DB2
or a GSKit keystore. All four checks are plugins from this repository.

> Deploy **either** this set **or** the per-plugin `service.conf` files — not
> both. They define apply rules of the same names, and Icinga refuses to start
> on a duplicate object.

**Tested against:** IBM Security Verify Directory 10.0.3 with DB2 11.5 on
AlmaLinux 9, in a two-server peer replication topology.

## Prerequisites

### 1. Install the four plugins on each SDS host

```
for p in check_isds_monitor check_isds_replication check_isds_backend check_isds_cert; do
  install -m 0755 "plugins/bash/$p/$p.sh" "/usr/lib64/nagios/plugins/$p"
done
```

> **Plugin path:** these examples use the AlmaLinux 9 path `/usr/lib64/nagios/plugins`.
> On Debian/Ubuntu it is `/usr/lib/nagios/plugins`. Confirm your distribution's
> `PluginDir` constant and adjust every path below, including the sudoers rule.

Install them **without the `.sh` extension**. The CheckCommands reference
`PluginDir + "/check_isds_monitor"`, not `check_isds_monitor.sh`.

Copy the files with `git pull`, `scp` or `install` rather than pasting them into
an editor; a pasted copy can be truncated. Check that each copy is complete:

```
for p in check_isds_monitor check_isds_replication check_isds_backend check_isds_cert; do
  f=/usr/lib64/nagios/plugins/$p
  bash -n "$f" && echo "$p $(grep -m1 PLUGIN_VERSION= "$f") $(wc -l < "$f") lines"
done
```

The line counts must match the repository. A truncated file gives
*syntax error: unexpected end of file*.

No LDAP or GSKit client needs to be on the `icinga` user's `PATH`. The plugins
find `idsldapsearch` under `/opt/*/ldap/*/bin` and the DB2-bundled
`gsk8capicmd_64` under `/opt/db2/*/gskit/bin` on their own.

### 2. Create the LDAP bind account and its password file

Both LDAP checks share one dedicated, read-only account. **Creating the monitor
bind account** in [check_isds_monitor/README.md](../../plugins/bash/check_isds_monitor/README.md#creating-the-monitor-bind-account)
gives the LDIF and the ACL.

Bind as a real entry, such as
`cn=icinga-monitor,cn=Users,cn=ServiceAccounts,cn=Auth,DC=COLLAB,DC=CLOUD`.
Do **not** use `cn=monitor` itself as the bind DN. It is the search base, not
an entry you can bind as, and the bind fails with LDAP rc=48
(*inappropriateAuthentication*).

```
install -d -o root -g icinga -m 0750 /etc/icinga2/secrets
install -o icinga -g icinga -m 0400 /dev/null /etc/icinga2/secrets/isds_monitor.pw
printf '%s' 'THE_PASSWORD' > /etc/icinga2/secrets/isds_monitor.pw
```

No plugin in the set takes a password on the command line. A command-line
password is visible to every user on the host in `ps`, and it would have to be
stored in plain text in a CheckCommand.

### 3. Sudoers for the backend check

`check_isds_backend` runs DB2 as the instance owner through `su - idsldap`,
and `su` needs root. Grant exactly one command, by its exact path:

```
# /etc/sudoers.d/icinga-isds
icinga ALL = (root) NOPASSWD: /usr/lib64/nagios/plugins/check_isds_backend
```

```
chmod 0440 /etc/sudoers.d/icinga-isds
visudo -c
```

The `check_isds_backend` command must then run through sudo. The shipped
`checkcommand.conf` does not, so the steps below change it. Without sudo, the
process sub-checks still work, but every DB2 sub-check reports UNKNOWN.

The other three checks run as the `icinga` user and need no sudo. The server
keystore and its stash are mode 0644.

## Method 1: Config File Deployment

On the **master** (or the config master of the zone the SDS hosts belong to):

```
cp plugins/bash/check_isds_monitor/icinga2/checkcommand.conf     /etc/icinga2/conf.d/isds-01-cmd-monitor.conf
cp plugins/bash/check_isds_replication/icinga2/checkcommand.conf /etc/icinga2/conf.d/isds-02-cmd-replication.conf
cp plugins/bash/check_isds_backend/icinga2/checkcommand.conf     /etc/icinga2/conf.d/isds-03-cmd-backend.conf
cp plugins/bash/check_isds_cert/icinga2/checkcommand.conf        /etc/icinga2/conf.d/isds-04-cmd-cert.conf

cp plugins/bash/check_isds_monitor/icinga2/service_template.conf     /etc/icinga2/conf.d/isds-10-tpl-monitor.conf
cp plugins/bash/check_isds_replication/icinga2/service_template.conf /etc/icinga2/conf.d/isds-11-tpl-replication.conf
cp plugins/bash/check_isds_backend/icinga2/service_template.conf     /etc/icinga2/conf.d/isds-12-tpl-backend.conf
cp plugins/bash/check_isds_cert/icinga2/service_template.conf        /etc/icinga2/conf.d/isds-13-tpl-cert.conf

cp servicesets/isds/host_template.conf /etc/icinga2/conf.d/isds-20-host-template.conf
cp servicesets/isds/services.conf      /etc/icinga2/conf.d/isds-21-services.conf
```

Route the backend check through sudo (prerequisite 3):

```
sed -i 's|command = \[ PluginDir + "/check_isds_backend" \]|command = [ "sudo", PluginDir + "/check_isds_backend" ]|' \
  /etc/icinga2/conf.d/isds-03-cmd-backend.conf
grep -n 'command =' /etc/icinga2/conf.d/isds-03-cmd-backend.conf
```

Then import the host template on each SDS host and override the placeholders:

```
object Host "ldap3.ams.cloud" {
  import "generic-host"
  import "isds-host"

  address = "10.0.0.13"

  vars.isds_ldap_binddn = "cn=icinga-monitor,cn=Users,cn=ServiceAccounts,cn=Auth,DC=COLLAB,DC=CLOUD"
  vars.isds_repl_base   = "DC=COLLAB,DC=CLOUD"
}

object Host "ldap4.ams.cloud" {
  import "generic-host"
  import "isds-host"

  address = "10.0.0.14"

  vars.isds_ldap_binddn = "cn=icinga-monitor,cn=Users,cn=ServiceAccounts,cn=Auth,DC=COLLAB,DC=CLOUD"
  vars.isds_repl_base   = "DC=COLLAB,DC=CLOUD"
}
```

Each SDS host must be an Icinga agent endpoint whose name matches the host
object, so that `command_endpoint = host.name` can reach it.

```
icinga2 daemon --validate
systemctl reload icinga2
icinga2 object list --type Service --name "isds-*"
```

## Method 2: Icinga Director (UI)

Minimum supported Director version: 1.10.0

### 1. Create the CheckCommands

Follow **Method 2 > Create CheckCommand** in each plugin's `INSTALL.md`. Each
one gives the full Arguments table for its command:

- [check_isds_monitor](../../plugins/bash/check_isds_monitor/INSTALL.md)
- [check_isds_replication](../../plugins/bash/check_isds_replication/INSTALL.md)
- [check_isds_backend](../../plugins/bash/check_isds_backend/INSTALL.md)
- [check_isds_cert](../../plugins/bash/check_isds_cert/INSTALL.md)

Enter every **Command** as a full absolute path:

| Command | Command field |
|---------|---------------|
| `check_isds_monitor` | `/usr/lib64/nagios/plugins/check_isds_monitor` |
| `check_isds_replication` | `/usr/lib64/nagios/plugins/check_isds_replication` |
| `check_isds_backend` | `/bin/sudo /usr/lib64/nagios/plugins/check_isds_backend` |
| `check_isds_cert` | `/usr/lib64/nagios/plugins/check_isds_cert` |

Director prepends the plugin directory to the first word of the command
whenever that word is not an absolute path. `$USER1$/check_isds_monitor` would
become a doubled path, and `sudo /usr/...` would make Director look for
`/usr/lib64/nagios/plugins/sudo`. Confirm the sudo path on the agent with
`command -v sudo`.

### 2. Create the Service Templates

Go to **Services > Service Templates > + Add** and create one template per
check. Set **Run on agent** to yes on every one:

| Name | Check command | Interval | Retry | Attempts |
|------|---------------|----------|-------|----------|
| `isds-monitor` | check_isds_monitor | 1m | 30s | 3 |
| `isds-replication` | check_isds_replication | 2m | 1m | 3 |
| `isds-backend` | check_isds_backend | 1m | 30s | 3 |
| `isds-cert` | check_isds_cert | 6h | 10m | 2 |

### 3. Create the Host Template

Go to **Hosts > Host Templates > + Add**:

```
Name:          isds-host
Check command: hostalive
```

On the **Custom Properties** tab, add every variable from `host_template.conf`.
Set them on the host template, which is where the services read them from:

| Variable | Type | Value |
|----------|------|-------|
| `isds` | Boolean | true |
| `isds_ldap_host` | String | `127.0.0.1` |
| `isds_ldap_port` | Number | `389` |
| `isds_ldap_binddn` | String | the service account DN |
| `isds_ldap_passfile` | String | `/etc/icinga2/secrets/isds_monitor.pw` |
| `isds_repl_base` | String | the directory suffix, e.g. `DC=COLLAB,DC=CLOUD` |
| `isds_backend_db2_instance` | String | `idsldap` |
| `isds_backend_db2_database` | String | `IDSLDAP` |
| `isds_backend_db2_user` | String | `idsldap` |
| `isds_cert_kdb` | String | `/data/idsldap/ssl/keystore.kdb` |
| `isds_cert_stash` | String | `/data/idsldap/ssl/keystore.sth` |

Keep the bind password out of Director. Set only `isds_ldap_passfile`, the path
to the mode 0400 file on the agent.

### 4. Create the Service Set

Go to **Services > Service Sets > + Add**:

```
Name:        ISDS
Description: IBM Security Directory Server health, replication, backend and certificate
```

Add the four services, each importing the template of the same name. The two
LDAP services need the shared connection mapped onto their own variables, as
`services.conf` does. Set these as custom properties on the services in the
set:

| Service | Custom property | Value |
|---------|-----------------|-------|
| `isds-monitor` | `isds_monitor_host` | `$isds_ldap_host$` |
| `isds-monitor` | `isds_monitor_port` | `$isds_ldap_port$` |
| `isds-monitor` | `isds_monitor_binddn` | `$isds_ldap_binddn$` |
| `isds-monitor` | `isds_monitor_passfile` | `$isds_ldap_passfile$` |
| `isds-replication` | `isds_repl_host` | `$isds_ldap_host$` |
| `isds-replication` | `isds_repl_port` | `$isds_ldap_port$` |
| `isds-replication` | `isds_repl_binddn` | `$isds_ldap_binddn$` |
| `isds-replication` | `isds_repl_passfile` | `$isds_ldap_passfile$` |

`isds-backend`, `isds-cert` and `isds_repl_base` need no mapping. Their host
variables already have the names the commands use, and Icinga looks up a macro
on the service first, then on the host, then on the command. The mapping above
is needed because the commands set their own defaults for host and port, and
the host's `isds_ldap_*` values have to override them. Without the mapping,
`isds-monitor` would connect to `$address$` instead of loopback.

Then assign the set to hosts:

```
host.templates contains "isds-host"
```

or `host.vars.isds is true`.

A Service Set is the Director equivalent of `services.conf`. It keeps the four
services together, so they are added, removed and assigned as one unit.

### 5. Import the host template

Import `isds-host` on each SDS host and override `isds_ldap_binddn` and
`isds_repl_base`. Each host must be an agent endpoint, so the **Icinga2 Agent**
option on the host must be enabled.

### 6. Deploy

Click **Deploy**. Changes in Director are not active until deployed.

## Verification

On each SDS host, run each check exactly as the agent will:

```
sudo -u icinga /usr/lib64/nagios/plugins/check_isds_monitor -H 127.0.0.1 \
  -D "cn=icinga-monitor,cn=Users,cn=ServiceAccounts,cn=Auth,DC=COLLAB,DC=CLOUD" \
  -y /etc/icinga2/secrets/isds_monitor.pw

sudo -u icinga /usr/lib64/nagios/plugins/check_isds_replication -H 127.0.0.1 \
  -D "cn=icinga-monitor,cn=Users,cn=ServiceAccounts,cn=Auth,DC=COLLAB,DC=CLOUD" \
  -y /etc/icinga2/secrets/isds_monitor.pw -b "DC=COLLAB,DC=CLOUD"

sudo -u icinga sudo -n /usr/lib64/nagios/plugins/check_isds_backend \
  --db2-instance idsldap --db2-database IDSLDAP --db2-user idsldap

sudo -u icinga /usr/lib64/nagios/plugins/check_isds_cert \
  --kdb /data/idsldap/ssl/keystore.kdb --stash /data/idsldap/ssl/keystore.sth
```

Run the backend line as `icinga` through `sudo -n`. That way it also proves
the sudoers rule works. If `sudo -n` asks for a password or is refused, the
agent will get the same result.

On the master, after the deploy:

```
icinga2 daemon -C --dump-objects
icinga2 object list --type Service --name "isds-*"
```

`icinga2 object list` reads the object cache, which may be stale. The first
command refreshes it. It validates the config but does not reload the daemon.

## Notes on three decisions

**Replication is checked on every server, not one.** An ISDS replication
agreement publishes its operational state (replication state, pending changes,
last change id) only on the **supplier** side. On the consumer side the entry
is configuration only, and the check reports an informational OK that says to
verify on the supplier. In a peer pair, each server is the supplier for one
direction, so checking only one server covers only one direction. The on-hold
flag (`ibm-replicationonhold`) is visible on both sides.

**Cache hit-ratio alerting is off by default.** ISVD 10.x reports cache
performance as `*_hit` / `*_miss` counters. On a healthy server the filter
cache sits around 40%, because many filters are only ever used once. A fixed
threshold would alert permanently. The ratios are always emitted as perfdata;
set `isds_monitor_cache_warn` / `_crit` on a host to alert on them.

**Only fixed-size tablespaces alert, and only personal certificates count.**
On an automatic-storage DB2 database, SYSCATSPACE runs at around 95% while
healthy, because DB2 grows it on demand. The backend check reports utilisation
for every tablespace but alerts only on tablespaces that cannot grow.
Similarly, a server keystore bundles CA roots, several of them long expired.
The cert check looks only at the personal certificate the server presents,
unless `isds_cert_all_certs` is set.

## License
MIT — see [LICENSE](../../LICENSE)
