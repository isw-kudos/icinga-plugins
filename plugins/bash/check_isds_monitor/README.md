# check_isds_monitor

Reads the `cn=monitor` backend of an IBM Security Directory Server (SDS — formerly
IBM Tivoli Directory Server, now IBM Security Verify Directory) over LDAP and
alerts on operational health that a plain bind/search check (`check_ldap`) cannot
see.

Four sub-checks (all enabled by default, individually toggleable):

| Sub-check     | What it catches                                                           |
|---------------|---------------------------------------------------------------------------|
| `workers`     | Worker thread pool exhaustion. Available workers at zero = server hung even though the LDAP port still accepts connections. |
| `connections` | Current connection count climbing toward a configured maximum.            |
| `throughput`  | Operation/search/bind counters, emitted as perfdata counters for rate graphing (informational, no thresholds). |
| `cache`       | Entry / filter / ACL / group-members cache hit ratios dropping low.       |

## Requirements
- Icinga 2 >= 2.13.0
- Bash >= 4.x
- An LDAP search client in `PATH`: the SDS-bundled `idsldapsearch` (preferred) or
  a standard `ldapsearch` (OpenLDAP client utilities)
- A bind account allowed to read `cn=monitor` (typically a read-only monitor DN)

## Creating the monitor bind account

Use a dedicated, least-privilege account — never the directory administrator
(`cn=root`) — so the monitoring credential cannot modify the directory. The same
account also works for `check_isds_replication`.

> SDS commands shown below are the bundled `idsldap*` tools; the OpenLDAP
> equivalents (`ldapadd`, `ldapsearch`) work too. Substitute your own suffix,
> host, and admin DN. Run these as the SDS instance owner (or any host with the
> client tools that can reach the server).
>
> **Passwords:** `-w PASSWORD` takes the password as its argument, so keep it
> next to the flag and quote it (`-w 'p@ss'`). To avoid the password in shell
> history use `-y FILE` (a file containing only the password) instead, or be
> prompted with `-w '?'` (the IBM `idsldap*` convention; the `?` is quoted so the
> shell does not glob it). With OpenLDAP tools the prompt flag is `-W`.

**1. Create the account.** Write the entry to an LDIF file (`monitor-acct.ldif`):

```ldif
dn: cn=icinga-monitor,ou=services,o=example
objectclass: inetOrgPerson
cn: icinga-monitor
sn: monitor
userPassword: CHANGE_ME_STRONG_PASSWORD
```

Add it, binding as your directory admin:

```
idsldapadd -h ldap01.example.com -p 389 -D "cn=root" -w '?' -f monitor-acct.ldif
```

**2. Grant read access to `cn=monitor`.** On most SDS deployments `cn=monitor` is
already readable by any authenticated bind, so step 1 may be enough — verify with
step 3 first. If the search returns *Insufficient access*, grant it explicitly by
adding an ACL to the monitor subtree (`monitor-acl.ldif`):

```ldif
dn: cn=monitor
changetype: modify
add: aclentry
aclentry: access-id:cn=icinga-monitor,ou=services,o=example:normal:rsc:sensitive:rsc:critical:rsc
```

```
idsldapmodify -h ldap01.example.com -p 389 -D "cn=root" -w '?' -f monitor-acl.ldif
```

The exact mechanism for restricting/granting monitor access varies by SDS / ISVD
version — some sites instead add the DN to the server's administrative group via
the Web Administration Tool (Server administration → Manage administrative group)
or with a `DirDataAdmin`/read-only role. Consult your version's documentation if
the ACL approach above does not apply.

**3. Verify the account can read `cn=monitor`:**

```
idsldapsearch -h ldap01.example.com -p 389 \
  -D "cn=icinga-monitor,ou=services,o=example" -w '?' \
  -b cn=monitor -s base "(objectclass=*)" available_workers currentconnections
```

A successful result lists the monitor attributes. *Insufficient access* or no
entry means revisit step 2.

**4. Store the password for Icinga** in a file readable only by the Icinga user,
and point the plugin at it with `-y` (see `INSTALL.md`):

```
install -o icinga -g icinga -m 0400 /dev/null /etc/icinga2/secrets/isds_monitor.pw
printf '%s' 'CHANGE_ME_STRONG_PASSWORD' > /etc/icinga2/secrets/isds_monitor.pw
```

## Compatibility
See Compatibility Matrix below.

## Usage
```
check_isds_monitor [-H host] [-p port] [--ldaps|-Z] [-D binddn] [-y passfile] \
                   [--monitor-base dn] [--workers-warn N] [--workers-crit N] \
                   [--conn-warn N] [--conn-crit N] [--cache-warn PCT] \
                   [--cache-crit PCT] [--no-workers|--no-connections| \
                   --no-throughput|--no-cache] [-t timeout] [-V] [-h]
```

## Arguments

| Argument          | Required | Default     | Description                                       |
|-------------------|----------|-------------|---------------------------------------------------|
| -H                | No       | 127.0.0.1   | LDAP host/IP                                      |
| -p                | No       | 389         | LDAP port                                         |
| --ldaps           | No       |             | Use `ldaps://` (set `-p` to the LDAPS port too)   |
| -Z                | No       |             | Use StartTLS on the plain port                    |
| -D                | No       |             | Bind DN (read-only monitor account)               |
| -W                | No       |             | Bind password (discouraged — visible in `ps`)     |
| -y                | No       |             | File holding the bind password (preferred)        |
| --monitor-base    | No       | cn=monitor  | Monitor search base                               |
| --workers-warn    | No       | 2           | Warn when available workers <= N                  |
| --workers-crit    | No       | 1           | Crit when available workers <= N                  |
| --conn-warn       | No       | (off)       | Warn when current connections >= N                |
| --conn-crit       | No       | (off)       | Crit when current connections >= N                |
| --cache-warn      | No       | 80          | Warn when a cache hit ratio < PCT%                |
| --cache-crit      | No       | 50          | Crit when a cache hit ratio < PCT%                |
| --no-workers      | No       |             | Disable the worker pool sub-check                 |
| --no-connections  | No       |             | Disable the connection count sub-check            |
| --no-throughput   | No       |             | Disable throughput counters                       |
| --no-cache        | No       |             | Disable cache hit-ratio sub-check                 |
| -t                | No       | 30          | Timeout in seconds                                |
| -V                | No       |             | Show version                                      |
| -h                | No       |             | Show help                                         |

## Example Output
```
check_isds_monitor OK - workers=OK connections=OK throughput=OK cache=OK | available_workers=14;2:;1:;0;16 total_workers=16 current_connections=37;;;0; total_connections=204815c ops_completed=9912034c searches_completed=8801221c entry_cache_hit_ratio=98%;80:;50:;0;100 filter_cache_hit_ratio=91%;80:;50:;0;100
[OK] available workers 14/16
[OK] 37 current connections
[OK] operation counters collected
[OK] cache hit ratios healthy
```

## Known Limitations
- `cn=monitor` attribute names differ slightly across SDS / ISVD versions. If a
  sub-check reports an attribute as "not found", adjust the attribute names in the
  *Attribute names* block near the top of the script. Defaults target classic SDS
  (`available_workers`, `total_workers`, `currentconnections`, `opscompleted`, …).
- Throughput values are raw cumulative counters; meaningful rates require Icinga to
  graph the `c` (counter) perfdata over time.
- Cache hit ratios are computed from cumulative hits/tries since server start, so a
  freshly restarted server may briefly show a low ratio.

## Compatibility Matrix

| Plugin Version | Icinga 2 Version | OS                     | Lang Version |
|----------------|------------------|------------------------|--------------|
| 1.0.0          | >= 2.13.0        | Ubuntu 22.04/24.04     | Bash 5.x     |
| 1.0.0          | >= 2.13.0        | Debian 11/12           | Bash 5.x     |
| 1.0.0          | >= 2.13.0        | RHEL / Rocky Linux 8/9 | Bash 4.x     |

## License
MIT - see LICENSE
