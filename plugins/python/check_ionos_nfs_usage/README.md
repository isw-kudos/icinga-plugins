# check_ionos_nfs_usage

Checks that the shares on an IONOS Cloud Network File Storage (NFS) cluster
together stay below the cluster's provisioned size.

All shares on a cluster draw from one pool of storage. When their combined usage
reaches the cluster size, the cluster goes read-only for **every** share at once
and the applications writing to it fail. Per-share quotas do not prevent this
unless they add up to no more than the cluster size. This check reads the
cluster and all of its shares from the
[IONOS NFS API](https://api.ionos.com/docs/nfs/v1/), adds up the usage, and
alerts when the total gets close to the cluster size.

## Requirements
- Icinga 2 >= 2.13.0
- Python >= 3.6 (runs on the stock `python3` of RHEL / Rocky / AlmaLinux 8).
  Standard library only, nothing to `pip install`.
- Outbound HTTPS from the checking node to `nfs.<location>.ionos.com`
- An IONOS API token for a user that can read the cluster (see
  [INSTALL.md](INSTALL.md#ionos-api-token))

## Compatibility
See Compatibility Matrix below.

## Usage
```
check_ionos_nfs_usage -L <location> [-C <cluster>] --token-file <path>
                      [-w <percent>] [-c <percent>] [-t <timeout>] [-V] [-h]
```

## Arguments

| Argument         | Required | Default        | Description |
|------------------|----------|----------------|-------------|
| -L / --location  | Yes¹     |                | IONOS location of the cluster: `de-fra`, `de-txl`, `es-vit`, `fr-par`, `gb-lhr`, `us-ewr`, `us-las`, `us-mci` |
| -U / --url       | Yes¹     |                | NFS API base URL instead of `--location`, e.g. for a proxy. Not in the CheckCommand |
| -C / --cluster   | No²      |                | Cluster ID or name |
| --token-file     | No³      | `$IONOS_TOKEN` | File whose first line is the IONOS API token |
| -w / --warning   | No       | 80             | WARNING when total usage reaches this percentage of the cluster size |
| -c / --critical  | No       | 90             | CRITICAL when total usage reaches this percentage of the cluster size |
| -t / --timeout   | No       | 30             | Timeout in seconds for the whole check |
| -V / --version   | No       |                | Show plugin version |
| -h / --help      | No       |                | Show help |

¹ Exactly one of `--location` and `--url`.
² Required when the location has more than one cluster. A name must be unique,
otherwise use the ID.
³ Without `--token-file` the token is read from the `IONOS_TOKEN` environment
variable. There is deliberately no option that takes the token itself, because
the command line is visible to every user in the process list.

## How usage is calculated

The API reports usage in two places, both in bytes:

- each share's `metadata.used`, which the plugin adds up, and
- the cluster's own `metadata.used`.

The check compares **the larger of the two** with the cluster size
(`properties.size` in `sizeUnit`, TiB or GiB). The share total is what fills the
cluster. The cluster figure also counts anything stored outside the shares, and
it still covers a share whose usage the API does not report. Both figures are in
the performance data, so you can graph them separately.

The API reports cluster usage as `0` when it cannot determine it, and leaves out
a share's `used` field when that share's usage is not available. If a share's
usage is missing **and** the cluster reports 0, the total cannot be trusted and
the check returns UNKNOWN.

## Behaviour

| Condition                                                   | State    |
|-------------------------------------------------------------|----------|
| Usage below `-w` percent of the cluster size                | OK       |
| Usage at or above `-w` percent                              | WARNING  |
| Usage at or above `-c` percent (including over 100%)        | CRITICAL |
| Share usage missing and the cluster reports none            | UNKNOWN  |
| API error: 401 (token invalid or expired), 403, 404, 429, 5xx | UNKNOWN |
| API unreachable, response not JSON, or check timed out      | UNKNOWN  |
| Cluster not found, ambiguous, or several and no `-C`        | UNKNOWN  |
| Bad or missing arguments, token file unreadable             | UNKNOWN  |

## Example Output
```
check_ionos_nfs_usage OK - nfs-prod: 870.00 GiB of 2.00 TiB used (42.5%), 1.15 TiB free, 3 share(s) | used=934155386880B;1759218604441;1979120929996;0;2199023255552 used_pct=42.48%;80;90;0;100 shares_used=934155386880B;;;0;2199023255552 cluster_used=934155386880B;;;0;2199023255552 'share_data'=751619276800B;;;0;1099511627776 'share_logs'=128849018880B;;;0;2199023255552 'share_home_dirs'=53687091200B;;;0;107374182400
Cluster nfs-prod (11111111-1111-1111-1111-111111111111): status AVAILABLE, size 2 TiB
Usage: shares total 870.00 GiB, cluster reports 870.00 GiB (the check uses the larger)
1 of 3 share(s) have no quota
Shares, largest first:
  data: 700.00 GiB (quota 1.00 TiB, 68.4%)
  logs: 120.00 GiB (no quota)
  home dirs: 50.00 GiB (quota 100.00 GiB, 50.0%)
```
```
check_ionos_nfs_usage CRITICAL - nfs-prod: 1.86 TiB of 2.00 TiB used (92.8%, critical at 90%), 148.00 GiB free, 2 share(s) | ...
check_ionos_nfs_usage UNKNOWN - HTTP 401 from /clusters - the token is missing, invalid or expired: Unauthorized, wrong or no api key provided to process this request
```

### Performance data

| Label           | Unit | Meaning |
|-----------------|------|---------|
| `used`          | B    | Usage the check alerts on (larger of the two figures below); warn/crit/max in bytes |
| `used_pct`      | %    | `used` as a percentage of the cluster size |
| `shares_used`   | B    | Sum of the shares' reported usage |
| `cluster_used`  | B    | Usage the cluster itself reports (0 when the API cannot determine it) |
| `share_<name>`  | B    | Usage per share; max is the share's quota, or the cluster size when it has none |

## Known Limitations
- The API documentation does not say how often `used` is refreshed. A share that
  fills up faster than the check interval plus that refresh delay can still hit
  the limit between checks. Lower the thresholds if your data grows in bursts.
- IONOS does not document the exact point at which a cluster goes read-only. The
  check assumes it is the provisioned size. If you see it happen earlier, lower
  the thresholds.
- One cluster per service. Monitor several clusters with one Icinga host each.
- API tokens expire. An expired token makes the check UNKNOWN, not CRITICAL, so
  make sure UNKNOWN notifies for this service, or the cluster can fill up
  unwatched.
- A single share reaching its own quota is listed in the long output but not
  alerted on. This check is about the shared pool.

## Compatibility Matrix

| Plugin Version | Icinga 2 Version | OS                           | Lang Version    |
|----------------|------------------|------------------------------|-----------------|
| 1.0.0          | >= 2.13.0        | RHEL / Rocky / AlmaLinux 8/9 | Python 3.6/3.9  |
| 1.0.0          | >= 2.13.0        | Ubuntu 22.04/24.04           | Python 3.10/3.12 |
| 1.0.0          | >= 2.13.0        | Debian 11/12                 | Python 3.9/3.11 |

Verified against Python 3.6.15 and 3.14.

## License
MIT - see [LICENSE](../../../LICENSE)
