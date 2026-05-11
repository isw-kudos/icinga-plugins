# check_cnx_search

Checks the freshness of an HCL Connections search index by querying its Atom feed
endpoint. Returns WARNING or CRITICAL when the index has not been updated within the
configured age thresholds.

## Requirements

- Icinga 2 >= 2.13.0
- Bash >= 4.x
- `curl`
- `xmllint` (package: `libxml2-utils` on Debian/Ubuntu, `libxml2` on RHEL/Rocky)
- `date` (GNU coreutils — Linux only)
- HCL Connections with search enabled and accessible

## Compatibility

See Compatibility Matrix below.

## Usage

```
check_cnx_search -H <url> -u <username> -p <password> [-w <warning_hours>] [-c <critical_hours>] [-t <timeout>] [-V] [-h]
```

## Arguments

| Argument          | Required | Default | Description                                           |
|-------------------|----------|---------|-------------------------------------------------------|
| -H                | Yes      |         | HCL Connections base URL (e.g. https://cnx.example.com) |
| -u                | Yes      |         | Username for authentication                           |
| -w / --warning    | No       | 20      | Warning threshold in hours                            |
| -c / --critical   | No       | 24      | Critical threshold in hours                           |
| -t / --timeout    | No       | 30      | Timeout in seconds                                    |
| -V                | No       |         | Show plugin version                                   |
| -h                | No       |         | Show help                                             |

## Example Output

```
check_cnx_search OK - Search index is fresh - last updated 2h 15m ago | age=8100s;72000;86400;0
check_cnx_search WARNING - Search index is aging - last updated 21h 5m ago | age=75900s;72000;86400;0
check_cnx_search CRITICAL - Search index is STALE - last updated 25h 0m ago | age=90000s;72000;86400;0
check_cnx_search UNKNOWN - Plugin timed out after 30 seconds
```

## Performance Data

| Label | UOM | Description                        |
|-------|-----|------------------------------------|
| age   | s   | Age of the search index in seconds |

Warn and crit thresholds are included in perfdata as seconds.

## Known Limitations

- Uses `date -d` (GNU date) — not compatible with macOS or BSD systems
- SSL certificate verification is disabled (`--insecure`) to support self-signed enterprise PKI
- Authenticates via HTTP Basic Auth — ensure HTTPS is used in production

## Compatibility Matrix

| Plugin Version | Icinga 2 Version | OS                     | Lang Version |
|----------------|------------------|------------------------|--------------|
| 1.0.0          | >= 2.13.0        | Ubuntu 22.04/24.04     | Bash 5.x     |
| 1.0.0          | >= 2.13.0        | Debian 11/12           | Bash 5.x     |
| 1.0.0          | >= 2.13.0        | RHEL / Rocky Linux 8/9 | Bash 4.x     |

## License

MIT - see [LICENSE](../../../LICENSE)
