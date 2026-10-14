# Installation Guide: check_isds_backend

## Table of Contents
- Requirements
- DB2 access (sudo / su) setup
- Plugin Installation
- Method 1: Config File Deployment
- Method 2: Icinga Director (UI)
- Verification

## Requirements
- Icinga 2 >= 2.13.0
- Bash >= 4.x
- Runs **locally on the SDS host** (install on the Icinga agent there, not the master)
- `pgrep` (procps) for the `proc` sub-check
- The DB2 CLI (`db2`) for the `db2-tablespace` and `db2-logs` sub-checks

### Confirm the process names
The `proc` sub-check matches `pgrep -f` against `ibmslapd`, `ibmdiradm`, and
`db2sysc`. Confirm these are the real process names on your host:

```
pgrep -af ibmslapd
pgrep -af ibmdiradm
pgrep -af db2sysc
```

If they differ on your SDS/DB2 version, edit the *Process patterns* block near the
top of `check_isds_backend.sh`.

## DB2 access (sudo / su) setup

DB2 commands must run **as the DB2 instance owner** (e.g. `dsrdbm01`). The Icinga
agent normally runs as an unprivileged `icinga`/`nagios` user, so it cannot run
`db2` directly. Two options:

**Option A — pass `--db2-user`.** The plugin wraps DB2 calls as
`su - <user> -c '<db2 commands>'`. `su` requires elevated privileges, so grant the
Icinga user a narrow sudo rule. Add a file under `/etc/sudoers.d/` (validate with
`visudo -c`):

```
# /etc/sudoers.d/icinga-check_isds_backend
icinga ALL=(root) NOPASSWD: /usr/lib64/nagios/plugins/check_isds_backend
```

Then have Icinga invoke the plugin through `sudo`. In a config file, change the
CheckCommand's command line:

```
object CheckCommand "check_isds_backend" {
  command = [ "sudo", PluginDir + "/check_isds_backend" ]
  ...
}
```

In Director, see **Method 2** below. The plugin then runs as root and
`su - <db2-user>` succeeds. Scope the sudo rule to this one plugin only.
Without sudo, the process sub-checks still work, but every `db2-*` sub-check
reports UNKNOWN.

> If you prefer not to give the plugin root, grant a precise `su` rule instead and
> have the plugin run under it — but the simplest, auditable approach is the
> single-plugin NOPASSWD rule above.

**Option B — run the plugin as the instance owner.** If your agent already runs
checks as the DB2 instance owner (or you arrange so via the Icinga `run_as`
mechanism), omit `--db2-user`; `db2` must then be in that user's `PATH`.

The DB2 instance and database names are passed via `--db2-instance` and
`--db2-database` (Icinga vars `isds_backend_db2_instance` /
`isds_backend_db2_database`). Both are required for the `db2-*` sub-checks; if
missing, those sub-checks report UNKNOWN (never crash).

## Plugin Installation

```
cp check_isds_backend.sh /usr/lib64/nagios/plugins/check_isds_backend
chmod +x /usr/lib64/nagios/plugins/check_isds_backend
```

> **Plugin path:** these examples use the AlmaLinux 9 path `/usr/lib64/nagios/plugins`
> (the 64-bit RHEL-family `PluginDir`). On Debian/Ubuntu it is `/usr/lib/nagios/plugins`
> — confirm your distribution's `PluginDir` constant and adjust the paths accordingly.
> The sudoers rule above must use the same path.

## Method 1: Config File Deployment

> **Deploying several ISDS checks?** Use the ISDS service set in
> [servicesets/isds](../../../servicesets/isds/README.md) instead of the
> per-plugin `service.conf` files. It ships one host template and all four
> apply rules. Deploy one or the other, never both: they define services of
> the same names.

### CheckCommand Definition
```
cp icinga2/checkcommand.conf /etc/icinga2/conf.d/check_isds_backend_command.conf
```

If you use `--db2-user` with the sudoers rule above, switch the copied command
to sudo:
```
sed -i 's|command = \[ PluginDir + "/check_isds_backend" \]|command = [ "sudo", PluginDir + "/check_isds_backend" ]|' \
  /etc/icinga2/conf.d/check_isds_backend_command.conf
```

### Service Template
```
cp icinga2/service_template.conf /etc/icinga2/conf.d/check_isds_backend_service_template.conf
```

The template sets the check interval and `command_endpoint = host.name`. The
check runs on the agent on the SDS host, because it inspects local processes and runs the local `db2` CLI.

### Service Definition
```
cp icinga2/service.conf /etc/icinga2/conf.d/check_isds_backend_service.conf
```

Set the DB2 details and the `isds` flag on the SDS host object, e.g.:
```
object Host "ldap01.example.com" {
  import "generic-host"
  address = "10.0.0.10"
  vars.isds = true
  vars.isds_backend_db2_instance = "idsldap"
  vars.isds_backend_db2_database = "IDSLDAP"
  vars.isds_backend_db2_user     = "idsldap"
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
2. Name: `check_isds_backend`, Command:
   `/bin/sudo /usr/lib64/nagios/plugins/check_isds_backend` with the sudoers
   rule above, or `/usr/lib64/nagios/plugins/check_isds_backend` without it.

   Enter every word as an absolute path, the sudo binary included. Director
   prepends the plugin directory to the first word of the command unless it is
   already absolute. `sudo ...` makes the agent look for
   `/usr/lib64/nagios/plugins/sudo`, and `$USER1$/check_isds_backend` becomes a
   doubled path. Confirm the sudo path on the agent with `command -v sudo`.
3. Arguments tab — add each argument below. *Type* is the Director value type,
   *Required* mirrors the CheckCommand (the `--db2-*` args are required only for the
   DB2 sub-checks), *Repeat key* (`repeat_key`) applies to array arguments, and
   *Skip key* shows the `set_if` boolean that gates a flag argument (boolean flags
   carry no value — set them only via their `set_if` var):

   | Argument            | Value                         | Type    | Required          | Repeat key | Skip key (set_if)              | Description                               |
   |---------------------|-------------------------------|---------|-------------------|------------|--------------------------------|-------------------------------------------|
   | --db2-instance      | `$isds_backend_db2_instance$` | String  | For db2-* checks  | No         | —                              | DB2 instance name                         |
   | --db2-database      | `$isds_backend_db2_database$` | String  | For db2-* checks  | No         | —                              | DB2 database name                         |
   | --db2-user          | `$isds_backend_db2_user$`     | String  | No                | No         | —                              | Run db2 as this OS user via su - USER -c  |
   | -w                  | `$isds_backend_tbsp_warn$`    | Number  | No                | No         | —                              | Tablespace warn threshold (percent)       |
   | -c                  | `$isds_backend_tbsp_crit$`    | Number  | No                | No         | —                              | Tablespace crit threshold (percent)       |
   | --log-warn          | `$isds_backend_log_warn$`     | Number  | No                | No         | —                              | Transaction-log warn threshold (percent)  |
   | --log-crit          | `$isds_backend_log_crit$`     | Number  | No                | No         | —                              | Transaction-log crit threshold (percent)  |
   | --diradm-crit       | (none)                        | Boolean | No                | No         | `$isds_backend_diradm_crit$`   | Treat a missing ibmdiradm as CRITICAL     |
   | --no-diradm         | (none)                        | Boolean | No                | No         | `$isds_backend_no_diradm$`     | Skip the ibmdiradm process check          |
   | --no-proc           | (none)                        | Boolean | No                | No         | `$isds_backend_no_proc$`       | Disable the process liveness sub-check    |
   | --no-db2-tablespace | (none)                        | Boolean | No                | No         | `$isds_backend_no_tablespace$` | Disable the DB2 tablespace sub-check      |
   | --no-db2-logs       | (none)                        | Boolean | No                | No         | `$isds_backend_no_logs$`       | Disable the DB2 transaction-log sub-check |
   | -t                  | `$isds_backend_timeout$`      | Number  | No                | No         | —                              | Timeout per external command (default 30) |

4. **Store**, then **Deploy**.

### Create Service Template
1. Director > Services > Service Templates > **+ Add**
2. Name: `isds-backend`, Check command: `check_isds_backend`
3. Check interval `1m`, Retry interval `30s`, Max check attempts `3`
4. **Run on agent**: Yes
5. **Store**

### Create Service
1. Director > Services > Apply Rules > **+ Add**
2. Name: `isds-backend`, Imports: `isds-backend` (the template above)
3. Set `isds_backend_db2_instance`, `isds_backend_db2_database` and
   `isds_backend_db2_user` on the host. The service reads them from there
   under the same names.
4. Assign tab: `host.vars.isds` is true
5. **Store**, then **Deploy**.

Always **Deploy** after changes in Director.

## Verification

Process check only (no DB2 needed):
```
/usr/lib64/nagios/plugins/check_isds_backend --no-db2-tablespace --no-db2-logs
```

Full check, run exactly as the agent will run it. This also proves the
sudoers rule:
```
sudo -u icinga sudo -n /usr/lib64/nagios/plugins/check_isds_backend \
  --db2-instance idsldap --db2-database IDSLDAP --db2-user idsldap
```

Expected (healthy host):
```
check_isds_backend OK - proc_ibmslapd=OK proc_db2=OK proc_ibmdiradm=OK db2_tablespace=OK db2_logs=OK | ...
```

If a `db2-*` sub-check returns `UNKNOWN`, the DB2 SQL may need adjusting for your
DB2 version — edit the *DB2 QUERY* blocks in the script. If `db2 CLI not found`,
either run as the instance owner or set `--db2-user`.

```
icinga2 object list --type Service --name "isds-backend"
journalctl -u icinga2 -f
```
