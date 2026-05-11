# check_itop_unassigned_tickets

Checks the number of unassigned tickets in an iTop ITSM instance via the REST/JSON API.
Returns WARNING or CRITICAL when the count of tickets with no assigned agent meets or
exceeds the configured thresholds.

## Requirements

- Icinga 2 >= 2.13.0
- Bash >= 4.x
- `curl`
- `python3` >= 3.6 (used for JSON parsing; typically pre-installed on all supported OS)
- iTop >= 2.7 with REST API enabled (`webservices/rest.php`)
- An iTop user with `REST Services User` profile granted

## Compatibility

See Compatibility Matrix below.

## Usage

```
check_itop_unassigned_tickets -H <url> -u <username> -p <password> [-w <warning>] [-c <critical>] [-C <class>] [-t <timeout>] [-V] [-h]
```

## Arguments

| Argument        | Required | Default  | Description                                               |
|-----------------|----------|----------|-----------------------------------------------------------|
| -H              | Yes      |          | iTop base URL (e.g. https://itop.example.com)             |
| -u              | Yes      |          | iTop API username                                         |
| -p              | Yes      |          | iTop API password                                         |
| -w              | No       | 1        | Warning threshold (unassigned ticket count)               |
| -c              | No       | 2        | Critical threshold (unassigned ticket count)              |
| -C              | No       | Incident | Ticket class: Incident, UserRequest, Change, Problem, ... |
| -t              | No       | 10       | Timeout in seconds                                        |
| -V              | No       |          | Show plugin version                                       |
| -h              | No       |          | Show help                                                 |

## Example Output

```
check_itop_unassigned_tickets OK - 0 unassigned Incident ticket(s) | unassigned_tickets=0;1;2;0
check_itop_unassigned_tickets WARNING - 1 unassigned Incident ticket(s): INC-0042 [assigned]: Server down | unassigned_tickets=1;1;2;0
check_itop_unassigned_tickets CRITICAL - 3 unassigned Incident ticket(s): INC-0042 [assigned]: Server down, INC-0043 [new]: Disk full, INC-0044 [new]: VPN issues | unassigned_tickets=3;1;2;0
check_itop_unassigned_tickets UNKNOWN - Plugin timed out after 10 seconds
```

## Performance Data

| Label               | UOM  | Description                        |
|---------------------|------|------------------------------------|
| unassigned_tickets  | (none) | Count of unassigned tickets      |

## Checking Multiple Ticket Classes

To check multiple classes (e.g. both Incident and UserRequest), deploy separate services
each with a different `-C` value. See [INSTALL.md](INSTALL.md) for details.

## Known Limitations

- Uses OQL `WHERE agent_id = 0` to detect unassigned tickets — verify this matches
  your iTop version's representation of unassigned agents
- iTop API user requires the `REST Services User` profile; insufficient permissions
  return a non-zero API code and UNKNOWN exit
- Tested against iTop REST API version 1.3

## Compatibility Matrix

| Plugin Version | Icinga 2 Version | OS                     | Lang Version |
|----------------|------------------|------------------------|--------------|
| 1.0.0          | >= 2.13.0        | Ubuntu 22.04/24.04     | Bash 5.x     |
| 1.0.0          | >= 2.13.0        | Debian 11/12           | Bash 5.x     |
| 1.0.0          | >= 2.13.0        | RHEL / Rocky Linux 8/9 | Bash 4.x     |

## License

MIT - see [LICENSE](../../../LICENSE)
