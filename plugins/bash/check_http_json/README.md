# check_http_json

Fetches a URL over HTTP(S), parses the JSON response, and verifies that one or
more fields match expected values. Any mismatch, non-2xx HTTP status, connection
failure, or unparseable body results in **CRITICAL**.

Field checks are expressed as `--expect '<jq-path>=<expected>'` and are fully
generic: the jq path can reach nested fields, and the flag is repeatable so a
single check can assert several fields at once. Custom request headers are
supported (repeatable), which allows checking vhost-routed endpoints addressed
by IP.

## Requirements
- Icinga 2 >= 2.13.0
- Bash >= 4.x
- `curl`
- `jq`

## Compatibility
See Compatibility Matrix below.

## Usage
```
check_http_json -U <url> --expect '<jq-path>=<value>' [--expect ...] \
                [--header '<name>: <value>' ...] [-k] [-t <timeout>] [-V] [-h]
```

## Arguments

| Argument          | Required | Default | Description                                                        |
|-------------------|----------|---------|--------------------------------------------------------------------|
| -U / --url        | Yes      |         | Target URL (e.g. `https://host/route.id`)                          |
| --expect          | Yes (>=1)|         | Field check `'<jq-path>=<expected>'`, e.g. `'.route=lhss'` (a bare key like `'route'` also works). Repeatable |
| --header          | No       |         | Custom request header, e.g. `'host: social.example.com'`. Repeatable |
| -k / --insecure   | No       | off     | Skip TLS certificate verification                                  |
| -t / --timeout    | No       | 30      | Timeout in seconds                                                 |
| -V / --version    | No       |         | Show plugin version                                                |
| -h / --help       | No       |         | Show help                                                          |

## Behaviour

| Condition                                   | State    |
|---------------------------------------------|----------|
| All `--expect` checks match, HTTP 2xx       | OK       |
| Any field mismatches or path missing/null   | CRITICAL |
| HTTP status not 2xx                          | CRITICAL |
| Connection refused / host unresolvable       | CRITICAL |
| Response body is not valid JSON              | CRITICAL |
| Request timed out                            | UNKNOWN  |
| Missing required args / bad `--expect` form  | UNKNOWN  |

## Example

Reproducing a vhost-routed, IP-addressed endpoint (equivalent to
`curl -k https://10.169.225.120/route.id -H "host: social.stuttgart.de"`
returning `{"route":"lhss"}`):

```
check_http_json -U https://10.169.225.120/route.id -k \
  --header 'host: social.stuttgart.de' \
  --expect '.route=lhss'
```

## Example Output
```
CHECK_HTTP_JSON OK - 1 field(s) matched: .route=lhss | time=0.084s;;;0 checks=1
CHECK_HTTP_JSON CRITICAL - .route expected=lhss got=xxxx | time=0.079s;;;0 checks=1
CHECK_HTTP_JSON CRITICAL - HTTP 503 from https://10.169.225.120/route.id | time=0.051s;;;0 checks=1
```

## Field paths (`--expect`)
The left-hand side of each `--expect` is a jq filter. A leading `.` is optional
for simple key paths — `route` and `.route` are equivalent, and `data.route`
becomes `.data.route`. Anything starting with `.`, `[`, or `(` is passed to jq
unchanged, so full expressions work too:
```
--expect 'route=lhss'          # bare key (auto-prefixed)
--expect '.route=lhss'         # dotted key
--expect '.data.route=nested'  # nested
--expect '.items[0].id=42'     # array index
```
A filter that does not compile is reported as UNKNOWN (operator error), not
CRITICAL.

## Known Limitations
- Comparisons are string-based: the extracted JSON value is compared as text
  (e.g. `.count=3` matches the number `3`). Booleans compare as `true`/`false`.
- An expected value that itself contains `=` is supported — only the first `=`
  in each `--expect` splits path from value.
- A field whose JSON value is `null` is treated the same as a missing path
  (CRITICAL), because `jq -e` reports null as failure.
- Only the response body and HTTP status are inspected; response headers are not
  validated.

## Compatibility Matrix

| Plugin Version | Icinga 2 Version | OS                     | Lang Version |
|----------------|------------------|------------------------|--------------|
| 1.1.0          | >= 2.13.0        | Ubuntu 22.04/24.04     | Bash 5.x     |
| 1.1.0          | >= 2.13.0        | Debian 11/12           | Bash 5.x     |
| 1.1.0          | >= 2.13.0        | RHEL / Rocky Linux 8/9 | Bash 4.x     |

## License
MIT - see LICENSE
