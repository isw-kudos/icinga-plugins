# check_domino_mail

Icinga/Nagios plugin for HCL Domino 14 mail servers on Linux. Detects both clean
failures and "zombie" states where Domino appears alive on the surface but is not
actually serving users.

## What it monitors

Seven independent sub-checks, each catching a different failure mode:

| # | Sub-check | What it proves |
|---|-----------|----------------|
| 1 | `status` | `domino status` reports server running |
| 2 | `nrpc_tcp` | Port 1352 accepts TCP connections |
| 3 | `nrpc_handshake` | NRPC server thread is alive (replies with bytes OR resets our probe — both prove reactivity). TIMEOUT is the zombie signal. |
| 4 | `show_server` | Command queue is processing AND parses uptime + Domino's own Availability Index |
| 5 | `nrpc_trace` | End-to-end NRPC works using Domino's own client (`trace <self>`) |
| 6 | `smtp` | Port 25 returns a `220` banner; explicit CRIT on `421 Server not ready` |
| 7 | `http` | HTTP task returns expected content; `401`/`403` count as healthy |

Each sub-check has independent timeouts and contributes a status; the plugin reports
the worst overall and gives per-check detail lines so you know exactly which layer is broken.

## Why the layering matters

A naive "is the process running?" or "is port 1352 open?" check passes for a
crashed-but-still-listening Domino. The kernel keeps accepting TCP connections,
the process still appears in `ps`, but real Notes clients hang because the NRPC
server thread or command queue is wedged. The layered design catches each failure
mode separately:

| Failure pattern | Diagnosis |
|-----------------|-----------|
| `status` fails | Server crashed or not started |
| `nrpc_tcp` fails, `status` OK | Firewall / binding issue |
| `nrpc_handshake=TIMEOUT` | NRPC server thread wedged → restart needed |
| `show_server` produces no output | Command queue wedged → restart needed |
| `nrpc_trace` fails | NRPC stack broken at protocol level |
| `smtp` / `http` fail in isolation | Individual task issue, server itself fine |

## Requirements

- Icinga 2 >= 2.13.0
- Bash >= 4.x
- HCL Domino >= 14.0 on Linux (developed and tested against 14.5)
- Nashcom Domino start script installed with `domino` command in PATH
  (<https://nashcom.github.io/domino-startscript/>)
- `python3` available (for the NRPC handshake probe)
- `curl` available (for the HTTP probe)
- Icinga 2 agent on the Domino host

**Sudoers entry required.** The Nashcom start script uses `su` to switch to the `notes`
user internally. When invoked by the Icinga agent user (`nagios`/`icinga`) this fails
with `su: Authentication failure`. Add a sudoers entry and configure the plugin to use
`sudo` — see [INSTALL.md](INSTALL.md) for details.

## Compatibility

See Compatibility Matrix below.

## Usage

```
check_domino_mail [options]
```

## Arguments

| Argument | Required | Default | Description |
|----------|----------|---------|-------------|
| `-H` | No | 127.0.0.1 | Host/IP to probe |
| `--nrpc-port` | No | 1352 | NRPC port |
| `--smtp-port` | No | 25 | SMTP port |
| `--http-url` | No | http://127.0.0.1/names.nsf?OpenDatabase | HTTP URL to probe |
| `--http-expect` | No | Domino | Expected substring in HTTP body |
| `-t` | No | 10 | Per network-probe timeout in seconds |
| `--handshake-timeout` | No | 5 | NRPC handshake timeout in seconds |
| `--domino-cmd` | No | domino | Path to Nashcom start script |
| `--cmd-timeout` | No | 20 | `domino cmd` timeout in seconds |
| `--no-status` | No | | Disable `domino status` sub-check |
| `--no-nrpc-tcp` | No | | Disable NRPC TCP-connect sub-check |
| `--no-nrpc-handshake` | No | | Disable NRPC handshake sub-check |
| `--no-show-server` | No | | Disable `show server` sub-check |
| `--no-nrpc-trace` | No | | Disable NRPC trace sub-check |
| `--no-smtp` | No | | Disable SMTP sub-check |
| `--no-http` | No | | Disable HTTP sub-check |
| `-V` / `--version` | No | | Show plugin version |
| `-h` / `--help` | No | | Show help |

## Example Output

Healthy server:

```
check_domino_mail OK - status=OK nrpc_tcp=OK nrpc_handshake=OK show_server=OK nrpc_trace=OK smtp=OK http=OK | ...
[OK] Domino Server is running (notes)
[OK] NRPC port 1352 reachable (6ms)
[OK] NRPC reset our probe - thread is alive (12ms)
[OK] Server up, elapsed=3 days 12:55:20, availability=93 (state: AVAILABLE)
[OK] Connected to server mail01.example.com/Org (847ms)
[OK] SMTP banner OK (8ms): 220 mail01.example.com ESMTP Domino
[OK] HTTP 200 (19ms)
```

Server in trouble (task-level, server core fine):

```
check_domino_mail CRITICAL - status=OK nrpc_tcp=OK nrpc_handshake=OK show_server=OK nrpc_trace=OK smtp=CRIT http=CRIT | ...
[OK] Domino Server is running (notes)
[OK] NRPC port 1352 reachable (6ms)
[OK] NRPC reset our probe - thread is alive (12ms)
[OK] Server up, elapsed=3 days 12:55:20, availability=93 (state: AVAILABLE)
[OK] Connected to server mail01.example.com/Org (847ms)
[CRIT] SMTP unavailable (421): 421 mail01 SMTP service not available
[CRIT] HTTP 500 from http://127.0.0.1/names.nsf?OpenDatabase (19ms)
```

## Performance Data

| Label | UOM | Description |
|-------|-----|-------------|
| `status_ms` | ms | Time to run `domino status` |
| `nrpc_tcp_ms` | ms | TCP connect time to NRPC port |
| `nrpc_handshake_ms` | ms | NRPC handshake probe round-trip |
| `show_server_ms` | ms | Time to run `domino cmd "show server"` |
| `nrpc_trace_ms` | ms | Time to run `domino cmd "trace <server>"` |
| `smtp_ms` | ms | SMTP banner response time |
| `http_ms` | ms | HTTP response time |

`U` is reported for any sub-check that timed out or was skipped.

## Design Notes

### Why the Nashcom start script instead of `server -c` directly?

`server -c "command"` is fire-and-forget. It queues the command and exits with
empty stdout — output goes to `console.log`, not back to the caller. The Nashcom
start script's `domino cmd "command" N` wrapper tails the console log and returns
real captured output. This is the only sane way to invoke Domino commands from a
monitoring script. It also handles user-switching to `notes` internally.

### Why is `ConnectionResetError` (RST) classified as healthy in the NRPC handshake?

Domino 14+ NRPC rejects invalid client hellos with a TCP RST. A truly wedged Domino
accepts the connection and then does nothing — that's the `TIMEOUT` outcome. RST
proves the NRPC server thread is alive and reading our bytes, so it counts as OK.

### Why do `401`/`403` count as healthy for the HTTP sub-check?

If the HTTP task is running but `names.nsf` requires authentication, curl gets a 401
or 403. That proves the HTTP task is alive and processing requests. A dead HTTP task
would time out or return 500 / connection refused.

### Why does `show_server` parse the Availability Index?

Domino computes its own `Availability Index` (0–100) and state (AVAILABLE / RESTRICTED
/ BUSY / NOT_AVAILABLE). This is a much better signal than guessing from external
probes. The plugin escalates to CRIT on NOT_AVAILABLE and WARN on RESTRICTED/BUSY.

## Known Issues

### `smtp=CRIT SMTP unavailable (421)`

Domino's SMTP listener is in a restricted state. Check:
- `tell smtp show config` from the Domino console
- `Server is restricted to:` in the server document
- SMTP enabled in `Configuration → Server → Configurations → Router/SMTP → Restrictions and Controls`

### `http=CRIT HTTP 500` with "No matching Web Site"

No Web Site document matches the `Host:` header. Quick fix: probe with the server hostname:

```
--http-url http://mail01.example.com/names.nsf?OpenDatabase
```

In Icinga, set `vars.check_domino_mail_http_url` on the affected host.

Proper fix: add a catch-all Web Site document in `names.nsf` with `*` in the
"Host names or addresses mapped to this site" field, then `tell http restart`.

## Compatibility Matrix

| Plugin Version | Icinga 2 Version | OS | Lang Version |
|----------------|------------------|----|--------------|
| 1.0.0 | >= 2.13.0 | RHEL / Rocky Linux 8/9 | Bash 4.x |
| 1.0.0 | >= 2.13.0 | Ubuntu 22.04/24.04 | Bash 5.x |

## License

MIT - see [LICENSE](../../../LICENSE)
