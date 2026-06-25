# Installation Guide: check_isds_cert

## Table of Contents
- Requirements
- Plugin Installation
- Method 1: Config File Deployment
- Method 2: Icinga Director (UI)
- Verification

## Requirements
- Icinga 2 >= 2.13.0
- Bash >= 4.x
- A GSKit CMS cert tool in `PATH` on the SDS host: `gsk8capicmd_64` (preferred),
  `gsk8capicmd`, or `idsgskcapicmd`
- GNU `date` (standard on the SDS Linux host)
- Read access for the Icinga user to the `.kdb`, the `.sth` stash, and the gsk binary

This check runs **locally on the SDS host** (via the Icinga 2 agent on that host),
because it reads the keystore from disk with the GSKit tool.

### Typical keystore / stash location
The keystore and stash live under the SDS instance directory, commonly:

```
/home/<instance>/idsslapd-<instance>/etc/<keystore>.kdb
/home/<instance>/idsslapd-<instance>/etc/<keystore>.sth
```

The actual filenames are whatever the `ibm-slapdSslKeyDatabase` /
`ibm-slapdSslKeyDatabasePW` (stash) attributes in `ibmslapd.conf` point to. Check
that file if unsure.

The GSKit binary is usually under the SDS install, e.g.:

```
/opt/IBM/ldap/V6.4/bin/gsk8capicmd_64
/opt/ibm/ldap/<ver>/bin/idsgskcapicmd
```

Either add that `bin` directory to the Icinga user's `PATH`, or symlink the gsk
binary into a directory already on `PATH`.

### File access
The Icinga user that executes the check must be able to **read** the keystore and
stash files and **execute** the gsk binary. The keystore/stash are normally owned
by the SDS instance owner with tight permissions, so either:

- add the Icinga user to the SDS instance group and grant group-read on the
  `.kdb`/`.sth`, or
- place a copy of the keystore+stash in a location readable by Icinga (kept in sync).

Prefer the stash file (`--stash`) over a password (`--password`) — a password
passed on the command line is visible in the process list (`ps`).

## Plugin Installation

```
cp check_isds_cert.sh /usr/lib64/nagios/plugins/check_isds_cert
chmod +x /usr/lib64/nagios/plugins/check_isds_cert
```

> **Plugin path:** these examples use the AlmaLinux 9 path `/usr/lib64/nagios/plugins`
> (the 64-bit RHEL-family `PluginDir`). On Debian/Ubuntu it is `/usr/lib/nagios/plugins`
> — confirm your distribution's `PluginDir` constant and adjust the paths accordingly.

Install on the node executing the check (the Icinga 2 agent on the SDS host) — not
the Icinga 2 master.

## Method 1: Config File Deployment

### CheckCommand Definition
```
cp icinga2/checkcommand.conf /etc/icinga2/conf.d/check_isds_cert_command.conf
```

### Service Definition
```
cp icinga2/service.conf /etc/icinga2/conf.d/check_isds_cert_service.conf
```

Set the keystore path, stash path and the `isds` flag on the SDS host object, e.g.:
```
object Host "ldap01.example.com" {
  import "generic-host"
  address = "10.0.0.10"
  vars.isds = true
  vars.isds_cert_kdb   = "/home/dsrdbm01/idsslapd-dsrdbm01/etc/serverkey.kdb"
  vars.isds_cert_stash = "/home/dsrdbm01/idsslapd-dsrdbm01/etc/serverkey.sth"
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
2. Name: `check_isds_cert`, Command: `$USER1$/check_isds_cert`
3. Arguments tab — add each argument below. *Type* is the Director value type and
   *Required* mirrors the CheckCommand. None of these arguments use a repeat key or
   skip key:

   | Argument   | Value                  | Type   | Required | Repeat key | Skip key | Description                                     |
   |------------|------------------------|--------|----------|------------|----------|-------------------------------------------------|
   | --kdb      | `$isds_cert_kdb$`      | String | **Yes**  | No         | —        | Path to the GSKit CMS keystore (.kdb)           |
   | --stash    | `$isds_cert_stash$`    | String | No       | No         | —        | Path to the .sth stash file (preferred)         |
   | --password | `$isds_cert_password$` | String | No       | No         | —        | Keystore password (discouraged - visible in ps) |
   | --label    | `$isds_cert_label$`    | String | No       | No         | —        | Check only this cert label (default: all certs) |
   | -w         | `$isds_cert_warn$`     | Number | No       | No         | —        | Warn when a cert expires within DAYS days       |
   | -c         | `$isds_cert_crit$`     | Number | No       | No         | —        | Crit when a cert expires within DAYS days       |
   | -t         | `$isds_cert_timeout$`  | Number | No       | No         | —        | Timeout in seconds (default 30)                 |

4. **Store**, then **Deploy**.

### Create Service
1. Director > Services > Apply Rules > **+ Add**
2. Name: `isds-cert`, Check command: `check_isds_cert`
3. Custom Properties: set `isds_cert_kdb`, `isds_cert_stash`
4. Assign tab: `host.vars.isds` is true
5. Set the check interval to something occasional (e.g. 6h) — a cert check does not
   need to run every minute.
6. **Store**, then **Deploy**.

Sensitive values (a keystore password): do not hardcode as a default var. Prefer
the stash file; if you must use a password, use a Director Data Field and a
secrets-store integration, never a command-line default.

## Verification

```
/usr/lib64/nagios/plugins/check_isds_cert \
  --kdb /home/dsrdbm01/idsslapd-dsrdbm01/etc/serverkey.kdb \
  --stash /home/dsrdbm01/idsslapd-dsrdbm01/etc/serverkey.sth
```

Expected (healthy keystore):
```
check_isds_cert OK - server_cert=OK soonest=OK | days_until_expiry_server_cert=512;30:;7:;; min_days_until_expiry=512;30:;7:;;
```

If a cert returns `UNKNOWN - could not find expiry date`, your GSKit version labels
the validity line differently — adjust `NOT_AFTER_REGEX` in the *Validity field
matching* block at the top of the script and re-run.

```
icinga2 object list --type Service --name "isds-cert"
journalctl -u icinga2 -f
```
