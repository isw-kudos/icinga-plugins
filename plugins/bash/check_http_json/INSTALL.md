# Installation Guide: check_http_json

## Table of Contents
- Requirements
- Plugin Installation
- Method 1: Config File Deployment
- Method 2: Icinga Director (UI)
- Verification

## Requirements
- Icinga 2 >= 2.13.0
- Bash >= 4.x
- `curl`
- `jq`
- Runs on the node that can reach the target URL (Icinga master, satellite, or
  agent). If the endpoint is only reachable from a specific network, install the
  plugin there and route the check via `command_endpoint`.

## Plugin Installation

```
cp check_http_json.sh /usr/lib/nagios/plugins/check_http_json
chmod +x /usr/lib/nagios/plugins/check_http_json
```

> **Plugin path:** Debian/Ubuntu use `/usr/lib/nagios/plugins` (the default
> `PluginDir`). On the RHEL family (RHEL / Rocky / AlmaLinux 8/9) the 64-bit path
> is `/usr/lib64/nagios/plugins` — confirm your distribution's `PluginDir`
> constant and adjust the paths accordingly.

## Method 1: Config File Deployment

### CheckCommand Definition
```
cp icinga2/checkcommand.conf /etc/icinga2/conf.d/check_http_json_command.conf
```

See `icinga2/checkcommand.conf` for full contents.

### Service Definition
```
cp icinga2/service.conf /etc/icinga2/conf.d/check_http_json_service.conf
```

See `icinga2/service.conf` for full contents. `http_json_expect` and
`http_json_headers` are **arrays** — the CheckCommand repeats `--expect` /
`--header` once per element. Set the URL, checks, and (optional) headers on the
host object, e.g.:

```
object Host "route-endpoint.example.com" {
  import "generic-host"
  address = "10.169.225.120"
  vars.http_json          = true
  vars.http_json_url      = "https://10.169.225.120/route.id"
  vars.http_json_insecure = true
  vars.http_json_expect   = [ ".route=lhss" ]
  vars.http_json_headers  = [ "host: social.stuttgart.de" ]
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
2. Name: `check_http_json`, Command: `$USER1$/check_http_json`
3. Arguments tab — add each argument below. *Type* is the Director value type,
   *Required* mirrors the CheckCommand, *Repeat key* (`repeat_key`) applies to
   array arguments (Director repeats the flag once per array element), and
   *Skip key* shows the `set_if` boolean that gates a flag argument (boolean flags
   carry no value — set them only via their `set_if` var):

   | Argument | Value                   | Type    | Required  | Repeat key | Skip key (set_if)        | Description                                              |
   |----------|-------------------------|---------|-----------|------------|--------------------------|----------------------------------------------------------|
   | -U       | `$http_json_url$`       | String  | Yes       | No         | —                        | Target URL (e.g. `https://host/route.id`)                |
   | --expect | `$http_json_expect$`    | Array   | Yes (>=1) | Yes        | —                        | Field check `'<jq-path>=<expected>'`, e.g. `'.route=lhss'` |
   | --header | `$http_json_headers$`   | Array   | No        | Yes        | —                        | Custom request header, e.g. `'host: social.example.com'`   |
   | -k       | (none)                  | Boolean | No        | No         | `$http_json_insecure$`   | Skip TLS certificate verification                        |
   | -t       | `$http_json_timeout$`   | Number  | No        | No         | —                        | Timeout in seconds (default 30)                          |

4. **Store**, then **Deploy**.

### Create Service
1. Director > Services > Apply Rules > **+ Add**
2. Name: `http-json`, Check command: `check_http_json`
3. Custom Properties: set `http_json_url`, `http_json_expect` (array),
   `http_json_headers` (array, optional), and `http_json_insecure` (optional)
4. Assign tab: `host.vars.http_json` is true
5. **Store**, then **Deploy**.

Always **Deploy** after changes in Director.

> Sensitive values (e.g. an `Authorization:` header carrying a token): do not
> hardcode them as default vars. Set them at host level or via a Director Data
> Field of type String, and prefer a secrets-store integration.

## Verification

Reproduce the motivating case (IP-addressed, vhost-routed, self-signed cert):
```
/usr/lib/nagios/plugins/check_http_json \
  -U https://10.169.225.120/route.id -k \
  --header 'host: social.stuttgart.de' \
  --expect '.route=lhss'
```

Expected output:
```
check_http_json OK - 1 field(s) matched: .route=lhss | time=0.084s;;;0 checks=1
```

A deliberate mismatch returns CRITICAL (exit 2):
```
/usr/lib/nagios/plugins/check_http_json \
  -U https://10.169.225.120/route.id -k \
  --header 'host: social.stuttgart.de' \
  --expect '.route=WRONG'
```

```
icinga2 object list --type Service --name "http-json"
journalctl -u icinga2 -f
```
