# check_isds_cert

Monitors TLS certificate expiry inside the GSKit CMS keystore (`.kdb`) used by an
IBM Security Directory Server (SDS — formerly IBM Tivoli Directory Server, now IBM
Security Verify Directory). Runs **locally** on the SDS host and uses the bundled
GSKit cert tool to read the keystore, parse each certificate's "not after" date,
and alert before a cert expires and silently breaks LDAPS.

By default every certificate in the keystore is checked and the one expiring
soonest is reported in the summary; you can also target a single label.

## Requirements
- Icinga 2 >= 2.13.0
- Bash >= 4.x
- A GSKit CMS cert tool (`gsk8capicmd_64` preferred, `gsk8capicmd`, or the
  SDS-bundled `idsgskcapicmd`). The plugin auto-locates it on `PATH` **and** under
  common GSKit install dirs (`/opt/db2/*/gskit/bin`, `/usr/local/ibm/gsk8_64/bin`,
  `/opt/ibm/gsk8_64/bin`, `/opt/IBM/ldap/*/bin`), and sets `LD_LIBRARY_PATH` to the
  matching GSKit lib dir — so no `PATH` change is needed for the Icinga user. Use
  `--gsk-bin PATH` to point at a specific binary.
- GNU `date` (the `date -d` syntax; standard on the SDS Linux host)
- The `.kdb` keystore and its `.sth` stash file must be readable by the Icinga user
  (they typically are — both are commonly world-readable)

## Compatibility
See Compatibility Matrix below.

## Usage
```
check_isds_cert --kdb PATH [--stash PATH | --password PW] [--label LABEL] \
                [-w DAYS] [-c DAYS] [-t timeout] [-V] [-h]
```

## Arguments

| Argument     | Required | Default | Description                                                        |
|--------------|----------|---------|--------------------------------------------------------------------|
| --kdb        | Yes      |         | Path to the GSKit CMS keystore (`.kdb`)                            |
| --stash      | No       |         | Path to the `.sth` stash file (preferred; unlocks via `-stashed`) |
| --password   | No       |         | Keystore password — **discouraged**, visible in `ps`              |
| --label      | No       |         | Check only this cert label. Omitted = check all personal certs, report soonest. |
| --all-certs  | No       |         | Check every cert incl. trusted CA roots; default personal only    |
| --gsk-bin    | No       | (auto)  | Path to the GSKit cert tool; auto-located if unset                |
| -w           | No       | 30      | Warn when a cert expires within DAYS days                         |
| -c           | No       | 7       | Crit when a cert expires within DAYS days                         |
| -t           | No       | 30      | Timeout in seconds                                                |
| -V           | No       |         | Show version                                                       |
| -h           | No       |         | Show help                                                          |

If neither `--stash` nor `--password` is given, the plugin still passes
`-stashed`, assuming a stash file sits next to the keystore (GSKit's default).
Prefer `--stash` over `--password`: a stash file keeps the keystore password out
of the process list.

## Example Output
```
check_isds_cert OK - ldap_ams_cloud=OK soonest=OK | days_until_expiry_ldap_ams_cloud=5264;30:;7:;; min_days_until_expiry=5264;30:;7:;;
[OK] 'ldap.ams.cloud' expires in 5264 days
```

## Known Limitations
- A keystore usually also bundles trusted CA roots, several of which are often
  long-expired (e.g. an Equifax root expired in 2018). To avoid false `CRITICAL`s
  the plugin by default checks **only personal certs** (the cert the server
  presents on LDAPS). Pass `--all-certs` to include the trusted CA roots as well.
- The exact field wording in `gsk*capicmd -cert -details` output varies by GSKit
  version (e.g. `Not After`, `Valid To`, `validTo`); the script handles the
  GSKit 8 / ISVD 10.x `Not After : YYYY M D HH:MM:SS GMT+TZ` format as well as
  formats GNU `date -d` understands. If a cert reports
  `UNKNOWN - could not find expiry date`, adjust the `NOT_AFTER_REGEX` value in the
  clearly-marked *Validity field matching* block near the top of the script.
- Likewise the `-cert -list` output format differs slightly across versions; the
  `parse_labels` helper strips common leading markers and header lines, but an
  unusual build may need tweaking.
- Requires GNU `date` (`date -d`). The plugin is intended to run on the SDS Linux
  host, where GNU `date` is standard. It will not work with BSD/macOS `date`.
- The plugin reads only the keystore on disk; it does not verify the cert the
  running SDS process actually presents on the wire.

## Compatibility Matrix

| Plugin Version | Icinga 2 Version | OS                     | Lang Version |
|----------------|------------------|------------------------|--------------|
| 1.1.1          | >= 2.13.0        | Ubuntu 22.04/24.04     | Bash 5.x     |
| 1.1.1          | >= 2.13.0        | Debian 11/12           | Bash 5.x     |
| 1.1.1          | >= 2.13.0        | RHEL / Rocky Linux 8/9 | Bash 4.x     |

## License
MIT - see LICENSE
