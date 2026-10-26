# Installation Guide: check_ionos_nfs_usage

## Table of Contents
- Requirements
- IONOS API Token
- Plugin Installation
- Method 1: Config File Deployment
  - CheckCommand Definition
  - Host Template
  - Service Template
  - Service Definition
  - Host Object
- Method 2: Icinga Director (UI)
  - Create Data Fields
  - Create CheckCommand
  - Create Host Template
  - Create Service Template
  - Create Service
  - Create Host
- Verification

## Requirements
- Icinga 2 >= 2.13.0
- Python >= 3.6, standard library only
- Outbound HTTPS (443) from the checking node to `nfs.<location>.ionos.com`
- An IONOS API token (next section)

The check reads the IONOS API, not the NFS cluster itself, so it runs on the
Icinga master or a satellite that has internet access. It does **not** need to
run on an agent, and it does not need the NFS share mounted.

## IONOS API Token

The NFS API authenticates with a bearer token. Generate one for a dedicated
monitoring user that can read the cluster. IONOS documents one privilege for
NFS, **Access and Manage Network File Storage** (group flag
`accessAndManageNFS`). It lets the user change and delete clusters and shares
too, and no read-only role is documented.

Try the monitoring user **without** that privilege first. If the verification
command below lists the cluster, keep it that way. If it returns HTTP 403, add
the user to a group that has the privilege, and protect the token like an admin
password.

Generate the token with any of:

- **DCD:** open the Token Manager and generate a token.
- **ionosctl:** `ionosctl token generate`
- **Auth API:** `curl -u '<user@example.com>' https://api.ionos.com/auth/v1/tokens/generate`,
  which returns `{"token": "..."}`

**Tokens expire.** Note the expiry date and renew the token before it runs
out. An expired token makes the check UNKNOWN (HTTP 401), so make sure UNKNOWN
states notify for this service.

Store the token in a file that only root and the Icinga user can read:

```
install -m 0640 -o root -g icinga /dev/null /etc/icinga2/ionos-nfs.token
vi /etc/icinga2/ionos-nfs.token      # paste the token as the first line
```

On Debian/Ubuntu the Icinga user and group are `nagios`, not `icinga`.

Never put the token in a host var, a Director custom property, or the command
line: all three are readable by far more people than the token file.

## Plugin Installation

```
cp check_ionos_nfs_usage.py /usr/lib64/nagios/plugins/check_ionos_nfs_usage
chmod 0755 /usr/lib64/nagios/plugins/check_ionos_nfs_usage
```

> **Plugin path:** the examples use `/usr/lib64/nagios/plugins`, the 64-bit
> RHEL-family path (RHEL / Rocky / AlmaLinux 8/9). Debian/Ubuntu use
> `/usr/lib/nagios/plugins`. Confirm your distribution's `PluginDir` constant and
> adjust the paths. The `.conf` files use `PluginDir` and need no change.

In a distributed setup, install the plugin on the node that executes the check
(the master or satellite of the zone the host object belongs to), together with
the token file.

## Method 1: Config File Deployment

### CheckCommand Definition

```
cp icinga2/checkcommand.conf /etc/icinga2/conf.d/check_ionos_nfs_usage_command.conf
```

See `icinga2/checkcommand.conf` for full contents.

### Host Template

```
cp icinga2/host_template.conf /etc/icinga2/conf.d/check_ionos_nfs_usage_host_template.conf
```

Edit `vars.ionos_nfs_location` to the cluster's location. See
`icinga2/host_template.conf` for full contents.

The host stands for the cluster. If the checking node can reach the cluster IP
(shown in the DCD and in the API as `connections[].ipAddress`), use it as the
host address and keep `hostalive`. Otherwise set `check_command = "dummy"`.

### Service Template

```
cp icinga2/service_template.conf /etc/icinga2/conf.d/check_ionos_nfs_usage_service_template.conf
```

Checks every 5 minutes. See `icinga2/service_template.conf` for full contents.

### Service Definition

```
cp icinga2/service.conf /etc/icinga2/conf.d/check_ionos_nfs_usage_service.conf
```

See `icinga2/service.conf` for full contents. The apply rule assigns on
`host.vars.ionos_nfs_usage == true`, which the host template sets.

### Host Object

```
object Host "ionos-nfs-prod" {
  import "ionos-nfs-cluster"
  address = "10.7.222.5"

  vars.ionos_nfs_location = "de-fra"
  // Only when the location has more than one cluster:
  vars.ionos_nfs_cluster  = "nfs-prod"
}
```

Validate and reload Icinga 2:

```
icinga2 daemon --validate
systemctl reload icinga2
```

## Method 2: Icinga Director (UI)

Assumes Icinga Director is installed and the Kickstart wizard has been
completed. Minimum supported Director version: 1.10.0

### Create Data Fields

Navigate to **Icinga Director > Define Data Fields** and add:

| Field name             | Caption                   | Data type |
|------------------------|---------------------------|-----------|
| `ionos_nfs_usage`      | Check IONOS NFS usage     | Boolean   |
| `ionos_nfs_location`   | IONOS location            | String    |
| `ionos_nfs_cluster`    | IONOS NFS cluster         | String    |
| `ionos_nfs_token_file` | IONOS API token file      | String    |
| `ionos_nfs_warning`    | NFS usage warning (%)     | Number    |
| `ionos_nfs_critical`   | NFS usage critical (%)    | Number    |
| `ionos_nfs_timeout`    | IONOS API timeout (s)     | Number    |

`ionos_nfs_token_file` holds the **path** to the token file, not the token.

### Create CheckCommand

1. Navigate to **Icinga Director > Commands > External Commands**
2. Click **+ Add**
3. Fill in:

   ```
   Name:        check_ionos_nfs_usage
   Command:     /usr/lib64/nagios/plugins/check_ionos_nfs_usage
   Description: Total share usage of an IONOS NFS cluster against its size
   ```

   Enter the full path. Director prepends `PluginDir` to a command that is not
   absolute, so `$USER1$/check_ionos_nfs_usage` would render as
   `PluginDir + "/$USER1$/check_ionos_nfs_usage"`. Check the result on the
   command's **Preview** tab.

4. Switch to the **Arguments** tab and add each argument below. *Type* is the
   Director value type and *Required* mirrors the CheckCommand. *Repeat key*
   (`repeat_key`) and *Skip key* (`set_if`) do not apply here: every argument
   takes a single value and none is a flag.

   | Argument       | Value                     | Type   | Required | Repeat key | Skip key (set_if) | Description |
   |----------------|---------------------------|--------|----------|------------|-------------------|-------------|
   | `-L`           | `$ionos_nfs_location$`    | String | Yes      | No         | —                 | IONOS location of the cluster, e.g. `de-fra` |
   | `-C`           | `$ionos_nfs_cluster$`     | String | No       | No         | —                 | Cluster ID or name; omit when the location has one cluster |
   | `--token-file` | `$ionos_nfs_token_file$`  | String | Yes      | No         | —                 | File whose first line is the IONOS API token |
   | `-w`           | `$ionos_nfs_warning$`     | Number | No       | No         | —                 | Warning percentage of the cluster size (default 80) |
   | `-c`           | `$ionos_nfs_critical$`    | Number | No       | No         | —                 | Critical percentage of the cluster size (default 90) |
   | `-t`           | `$ionos_nfs_timeout$`     | Number | No       | No         | —                 | Timeout in seconds (default 30) |

5. Switch to the **Custom Properties** tab and set the defaults:

   ```
   ionos_nfs_warning  = 80
   ionos_nfs_critical = 90
   ionos_nfs_timeout  = 30
   ```

6. Click **Store**

### Create Host Template

1. Navigate to **Icinga Director > Hosts > Host Templates**
2. Click **+ Add**
3. Fill in:

   ```
   Name:          ionos-nfs-cluster
   Check command: hostalive      (or dummy if the cluster IP is not reachable)
   ```

4. Switch to the **Fields** tab and add the data fields `ionos_nfs_usage`,
   `ionos_nfs_location`, `ionos_nfs_cluster`, `ionos_nfs_token_file`,
   `ionos_nfs_warning` and `ionos_nfs_critical`
5. Switch to the **Custom Properties** tab and set:

   ```
   ionos_nfs_usage      = true
   ionos_nfs_token_file = /etc/icinga2/ionos-nfs.token
   ```

6. Click **Store**

### Create Service Template

1. Navigate to **Icinga Director > Services > Service Templates**
2. Click **+ Add**
3. Fill in:

   ```
   Name:               ionos-nfs-usage
   Check command:      check_ionos_nfs_usage
   Run on agent:       No
   Check interval:     5m
   Retry interval:     1m
   Max check attempts: 3
   ```

4. Click **Store**

### Create Service

1. Navigate to **Icinga Director > Services > Apply Rules**
2. Click **+ Add**
3. Fill in:

   ```
   Name:    ionos-nfs-usage
   Imports: ionos-nfs-usage
   ```

4. Leave the **Custom Properties** unset, so the values come from the host and
   the thresholds from the CheckCommand defaults
5. Switch to the **Assign** tab and add the rule `host.vars.ionos_nfs_usage` is
   true
6. Click **Store**

### Create Host

1. Navigate to **Icinga Director > Hosts > Hosts**
2. Click **+ Add**
3. Fill in:

   ```
   Hostname: ionos-nfs-prod
   Imports:  ionos-nfs-cluster
   Address:  <cluster IP, if hostalive is used>
   ```

4. Set `ionos_nfs_location` (e.g. `de-fra`), and `ionos_nfs_cluster` if the
   location has more than one cluster
5. Click **Store**, then **Deploy**

Always trigger a **Deploy** after changes in Director. Changes are not active
until deployed.

## Verification

Run the plugin as the Icinga user, which is what will execute it, so the token
file permissions are tested too:

```
sudo -u icinga /usr/lib64/nagios/plugins/check_ionos_nfs_usage -L de-fra \
  --token-file /etc/icinga2/ionos-nfs.token
```

Expected output (first line, followed by the per-share breakdown):

```
check_ionos_nfs_usage OK - nfs-prod: 870.00 GiB of 2.00 TiB used (42.5%), 1.15 TiB free, 3 share(s) | used=934155386880B;...
```

Common first-run results:

| Output | Cause |
|--------|-------|
| `UNKNOWN - cannot read token file ...: Permission denied` | Token file not readable by the Icinga user; fix owner/group/mode |
| `UNKNOWN - HTTP 401 from /clusters - the token is missing, invalid or expired` | Token wrong or expired; generate a new one |
| `UNKNOWN - HTTP 403 from /clusters ...` | The token's user lacks the Network File Storage privilege |
| `UNKNOWN - no NFS clusters found in this location` | Wrong `-L`, or the user cannot see the cluster |
| `UNKNOWN - 2 clusters found, select one with --cluster: ...` | Set `ionos_nfs_cluster` to one of the listed names or IDs |
| `UNKNOWN - cannot reach https://nfs.de-fra.ionos.com: ...` | No outbound HTTPS from this node |

Then check the service object. `icinga2 object list` reads a cache file, which
can be stale. Refresh it first (this validates only, it does not reload):

```
icinga2 daemon -C --dump-objects
icinga2 object list --type Service --name "ionos-nfs-usage"
journalctl -u icinga2 -f
```
