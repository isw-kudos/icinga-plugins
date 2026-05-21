#!/usr/bin/env bash
# MIT License
# Copyright (c) 2025 ISW Kudos
# https://github.com/isw-kudos/icinga-plugins/blob/main/LICENSE
#
# check_domino_mail - Icinga/Nagios plugin for HCL Domino on Linux
#
# Requires the Nashcom Domino start script (https://nashcom.github.io/
# domino-startscript/) installed on the Domino host with the 'domino'
# command available in PATH. The start script handles user transitions,
# data-directory awareness, and (critically) captures real command
# output via 'domino cmd', which Domino's bare 'server -c' does not.
#
# Sub-checks (in escalating depth):
#   1. status         - 'domino status' reports server running
#   2. nrpc_tcp       - TCP 1352 reachable within timeout
#   3. nrpc_handshake - Bytes flow back over NRPC socket OR Domino sends
#                       RST in response to our probe payload (both prove
#                       the NRPC server thread is alive). Catches the
#                       "TCP accepts but NRPC thread is dead" zombie.
#   4. show_server    - 'domino cmd "show server"' returns expected fields
#                       (catches command-queue wedge; reports availability)
#   5. nrpc_trace     - 'domino cmd "trace <self>"' connects via NRPC client
#   6. smtp           - TCP 25 reachable AND speaks SMTP
#   7. http           - HTTP endpoint returns expected content
#
# Exit codes: 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN
#

set -euo pipefail

PLUGIN_NAME="check_domino_mail"
PLUGIN_VERSION="1.0.0"

# ---------- Defaults ----------
HOST="127.0.0.1"
NRPC_PORT=1352
SMTP_PORT=25
HTTP_URL="http://127.0.0.1/names.nsf?OpenDatabase"
HTTP_EXPECT="Domino"
TIMEOUT=10
CMD_TIMEOUT=20
HANDSHAKE_TIMEOUT=5

CHECK_STATUS=1
CHECK_NRPC_TCP=1
CHECK_NRPC_HANDSHAKE=1
CHECK_SHOW_SERVER=1
CHECK_NRPC_TRACE=1
CHECK_SMTP=1
CHECK_HTTP=1

STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3

STATUS=${STATE_OK}
SUMMARY=()
DETAILS=()
PERFDATA=()

usage() {
    cat <<EOF
Usage: ${PLUGIN_NAME} [options]

Network probes:
  -H HOST                Host/IP to check (default: ${HOST})
  --nrpc-port PORT       NRPC port (default: ${NRPC_PORT})
  --smtp-port PORT       SMTP port (default: ${SMTP_PORT})
  --http-url URL         HTTP URL to probe (default: ${HTTP_URL})
  --http-expect STR      Expected substring in HTTP body (default: ${HTTP_EXPECT})
  -t SECONDS             Per network-probe timeout (default: ${TIMEOUT})
  --handshake-timeout S  NRPC handshake timeout (default: ${HANDSHAKE_TIMEOUT})

Domino start script integration:
  --cmd-timeout S        'domino cmd' timeout (default: ${CMD_TIMEOUT})

Sub-check toggles:
  --no-status            Disable 'domino status' check
  --no-nrpc-tcp          Disable NRPC TCP-connect check
  --no-nrpc-handshake    Disable NRPC byte-flow handshake check
  --no-show-server       Disable 'show server' console check
  --no-nrpc-trace        Disable NRPC end-to-end 'trace' check
  --no-smtp              Disable SMTP check
  --no-http              Disable HTTP check
  -V, --version          Show version
  -h, --help             Show this help

Exit codes: 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -H) HOST="$2"; shift 2 ;;
        --nrpc-port) NRPC_PORT="$2"; shift 2 ;;
        --smtp-port) SMTP_PORT="$2"; shift 2 ;;
        --http-url) HTTP_URL="$2"; shift 2 ;;
        --http-expect) HTTP_EXPECT="$2"; shift 2 ;;
        -t) TIMEOUT="$2"; shift 2 ;;
        --handshake-timeout) HANDSHAKE_TIMEOUT="$2"; shift 2 ;;
        --cmd-timeout) CMD_TIMEOUT="$2"; shift 2 ;;
        --no-status) CHECK_STATUS=0; shift ;;
        --no-nrpc-tcp) CHECK_NRPC_TCP=0; shift ;;
        --no-nrpc-handshake) CHECK_NRPC_HANDSHAKE=0; shift ;;
        --no-show-server) CHECK_SHOW_SERVER=0; shift ;;
        --no-nrpc-trace) CHECK_NRPC_TRACE=0; shift ;;
        --no-smtp) CHECK_SMTP=0; shift ;;
        --no-http) CHECK_HTTP=0; shift ;;
        -V|--version) echo "${PLUGIN_NAME} v${PLUGIN_VERSION}"; exit "${STATE_OK}" ;;
        -h|--help) usage; exit "${STATE_UNKNOWN}" ;;
        *) echo "${PLUGIN_NAME} UNKNOWN - Unrecognized option: $1"; exit "${STATE_UNKNOWN}" ;;
    esac
done

escalate() {
    local lvl=$1
    if (( lvl > STATUS )); then STATUS=$lvl; fi
}

record() {
    local lvl=$1 short=$2 detail=$3
    local tag
    case $lvl in
        "${STATE_OK}")       tag="OK"      ;;
        "${STATE_WARNING}")  tag="WARN"    ;;
        "${STATE_CRITICAL}") tag="CRIT"    ;;
        *)                   tag="UNKNOWN" ;;
    esac
    SUMMARY+=("$short=$tag")
    DETAILS+=("[$tag] $detail")
    escalate "$lvl"
}

now_ms() { date +%s%3N; }

DOMINO_RC=0
run_domino_cmd() {
    local cmd=$1 lines=${2:-50} out
    DOMINO_RC=0
    out=$(timeout --kill-after=2 "$CMD_TIMEOUT" \
            domino cmd "$cmd" "$lines" 2>&1) || DOMINO_RC=$?
    printf '%s' "$out"
}

extract_cmd_output() {
    local raw=$1
    local inner
    inner=$(echo "$raw" | awk '
        /^[[:space:]]*--- Console Output for / { capture=1; next }
        /^--- End of Console Output ---/      { capture=0 }
        capture { print }
    ')
    if [[ -z "$inner" ]]; then
        return
    fi
    echo "$inner" | awk '
        seen { print; next }
        /^[0-9]{2}\.[0-9]{2}\.[0-9]{4}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}/ { next }
        { seen=1; next }
    '
}

check_status() {
    local start end elapsed out rc=0
    start=$(now_ms)
    out=$(timeout --kill-after=2 10 domino status 2>&1) || rc=$?
    end=$(now_ms); elapsed=$((end - start))

    if [[ $rc -eq 124 || $rc -eq 137 ]]; then
        record ${STATE_CRITICAL} "status" "'domino status' timed out (${elapsed}ms)"
        PERFDATA+=("status_ms=U")
        return
    fi
    if ! command -v domino >/dev/null 2>&1; then
        record ${STATE_UNKNOWN} "status" "domino not found - install Nashcom start script"
        PERFDATA+=("status_ms=U")
        return
    fi

    if echo "$out" | grep -qiE "Domino Server is running"; then
        local user_part
        user_part=$(echo "$out" | grep -iE "Domino Server is running" | head -n1 \
                    | sed 's/^[[:space:]]*//')
        record ${STATE_OK} "status" "$user_part (${elapsed}ms)"
        PERFDATA+=("status_ms=${elapsed}ms")
    elif echo "$out" | grep -qiE "Domino Server is (not running|stopped)"; then
        record ${STATE_CRITICAL} "status" "Domino Server is NOT running"
        PERFDATA+=("status_ms=${elapsed}ms")
    else
        record ${STATE_UNKNOWN} "status" "Unrecognized 'domino status' output: $(echo "$out" | tail -n1)"
        PERFDATA+=("status_ms=${elapsed}ms")
    fi
}

tcp_probe() {
    local host=$1 port=$2 to=$3 start end
    start=$(now_ms)
    if timeout "$to" bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null; then
        exec 3<&- 3>&- 2>/dev/null || true
        end=$(now_ms); echo $((end - start)); return 0
    fi
    end=$(now_ms); echo $((end - start)); return 1
}

check_nrpc_tcp() {
    local elapsed
    if elapsed=$(tcp_probe "$HOST" "$NRPC_PORT" "$TIMEOUT"); then
        record ${STATE_OK} "nrpc_tcp" "NRPC port ${NRPC_PORT} reachable (${elapsed}ms)"
        PERFDATA+=("nrpc_tcp_ms=${elapsed}ms;;;0;$((TIMEOUT*1000))")
    else
        record ${STATE_CRITICAL} "nrpc_tcp" "NRPC port ${NRPC_PORT} unreachable within ${TIMEOUT}s"
        PERFDATA+=("nrpc_tcp_ms=U;;;0;$((TIMEOUT*1000))")
    fi
}

nrpc_handshake_once() {
    local start end elapsed got=""
    start=$(now_ms)
    local outer_to=$((HANDSHAKE_TIMEOUT + 2))
    # RST in response to our probe payload still proves the NRPC thread is alive.
    # TIMEOUT is the zombie signal: TCP accepted but NRPC thread never reads our bytes.
    got=$(timeout "$outer_to" python3 - "$HOST" "$NRPC_PORT" "$HANDSHAKE_TIMEOUT" <<'PY' 2>/dev/null
import socket, sys, errno
host, port, to = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
try:
    s = socket.create_connection((host, port), timeout=to)
    s.settimeout(to)
    try:
        s.sendall(b"\x00\x00\x00\x00")
        data = s.recv(64)
        s.close()
        sys.stdout.write("BYTES" if data else "EMPTY")
    except socket.timeout:
        sys.stdout.write("TIMEOUT")
    except ConnectionResetError:
        sys.stdout.write("RST")
    except OSError as e:
        if e.errno in (errno.ECONNRESET, errno.EPIPE):
            sys.stdout.write("RST")
        else:
            sys.stdout.write("FAIL")
except socket.timeout:
    sys.stdout.write("TIMEOUT")
except ConnectionRefusedError:
    sys.stdout.write("REFUSED")
except OSError:
    sys.stdout.write("FAIL")
PY
) || true
    end=$(now_ms); elapsed=$((end - start))
    echo "$elapsed:$got"
}

check_nrpc_handshake() {
    if ! command -v python3 >/dev/null 2>&1; then
        record ${STATE_UNKNOWN} "nrpc_handshake" "python3 not available"
        return
    fi

    local result elapsed status
    result=$(nrpc_handshake_once)
    elapsed="${result%%:*}"
    status="${result##*:}"

    case "$status" in
        BYTES)
            record ${STATE_OK} "nrpc_handshake" "NRPC responded with data (${elapsed}ms)"
            PERFDATA+=("nrpc_handshake_ms=${elapsed}ms;;;0;$((HANDSHAKE_TIMEOUT*1000))")
            return
            ;;
        RST)
            record ${STATE_OK} "nrpc_handshake" \
                "NRPC reset our probe - thread is alive (${elapsed}ms)"
            PERFDATA+=("nrpc_handshake_ms=${elapsed}ms;;;0;$((HANDSHAKE_TIMEOUT*1000))")
            return
            ;;
    esac

    sleep 1
    local result2 elapsed2 status2
    result2=$(nrpc_handshake_once)
    elapsed2="${result2%%:*}"
    status2="${result2##*:}"

    if [[ "$status2" == "BYTES" || "$status2" == "RST" ]]; then
        record ${STATE_WARNING} "nrpc_handshake" \
            "NRPC handshake recovered on retry (1st: $status / ${elapsed}ms, 2nd: $status2 / ${elapsed2}ms)"
        PERFDATA+=("nrpc_handshake_ms=${elapsed2}ms;;;0;$((HANDSHAKE_TIMEOUT*1000))")
        return
    fi

    local detail
    case $status in
        TIMEOUT) detail="NRPC connection accepted but never responded - server likely wedged" ;;
        EMPTY)   detail="NRPC closed cleanly with no data - unusual, possible proxy issue" ;;
        REFUSED) detail="NRPC port not listening (connection refused)" ;;
        FAIL)    detail="NRPC handshake failed at socket level" ;;
        *)       detail="NRPC handshake failed (status=$status)" ;;
    esac
    record ${STATE_CRITICAL} "nrpc_handshake" "$detail (2 attempts: $status, $status2)"
    PERFDATA+=("nrpc_handshake_ms=U;;;0;$((HANDSHAKE_TIMEOUT*1000))")
}

SERVER_NAME=""
check_show_server() {
    local raw out start end elapsed
    start=$(now_ms)
    raw=$(run_domino_cmd "show server" 100)
    end=$(now_ms); elapsed=$((end - start))

    if [[ ${DOMINO_RC} -eq 124 || ${DOMINO_RC} -eq 137 ]]; then
        record ${STATE_CRITICAL} "show_server" \
            "'domino cmd' timed out after ${CMD_TIMEOUT}s - command queue likely wedged"
        PERFDATA+=("show_server_ms=U;;;0;$((CMD_TIMEOUT*1000))")
        return
    fi
    if [[ ${DOMINO_RC} -ne 0 ]]; then
        record ${STATE_CRITICAL} "show_server" \
            "'domino cmd' failed (rc=${DOMINO_RC}): $(echo "$raw" | tail -n1)"
        PERFDATA+=("show_server_ms=${elapsed}ms;;;0;$((CMD_TIMEOUT*1000))")
        return
    fi

    out=$(extract_cmd_output "$raw")
    if [[ -z "$out" ]]; then
        record ${STATE_CRITICAL} "show_server" \
            "'show server' produced no output - command queue likely wedged (${elapsed}ms)"
        PERFDATA+=("show_server_ms=${elapsed}ms;;;0;$((CMD_TIMEOUT*1000))")
        return
    fi

    if ! echo "$out" | grep -q "^Server name:"; then
        record ${STATE_WARNING} "show_server" \
            "'show server' returned but no 'Server name:' field (${elapsed}ms)"
        PERFDATA+=("show_server_ms=${elapsed}ms;;;0;$((CMD_TIMEOUT*1000))")
        return
    fi

    SERVER_NAME=$(echo "$out" | awk -F':[[:space:]]+' \
                  '/^Server name:/ { sub(/[[:space:]]+-.*$/, "", $2); print $2; exit }')

    local elapsed_field avail_field
    elapsed_field=$(echo "$out" | sed -n 's/^Elapsed time:[[:space:]]*//p' | head -n1)
    avail_field=$(echo "$out" | sed -n 's/^Availability Index:[[:space:]]*//p' | head -n1)

    local summary="Server up"
    [[ -n "$elapsed_field" ]] && summary+=", elapsed=$elapsed_field"
    [[ -n "$avail_field" ]]   && summary+=", availability=$avail_field"

    if echo "$avail_field" | grep -qiE "NOT_AVAILABLE|UNAVAILABLE"; then
        record ${STATE_CRITICAL} "show_server" "$summary (Domino reports unavailable)"
    elif echo "$avail_field" | grep -qiE "RESTRICTED|BUSY"; then
        record ${STATE_WARNING} "show_server" "$summary (Domino in restricted/busy state)"
    else
        record ${STATE_OK} "show_server" "$summary"
    fi
    PERFDATA+=("show_server_ms=${elapsed}ms;;;0;$((CMD_TIMEOUT*1000))")
}

check_nrpc_trace() {
    local raw out start end elapsed
    if [[ -z "$SERVER_NAME" ]]; then
        record ${STATE_UNKNOWN} "nrpc_trace" \
            "Server name unknown (show_server must run first or succeed)"
        return
    fi

    start=$(now_ms)
    raw=$(run_domino_cmd "trace $SERVER_NAME" 50)
    end=$(now_ms); elapsed=$((end - start))

    if [[ ${DOMINO_RC} -eq 124 || ${DOMINO_RC} -eq 137 ]]; then
        record ${STATE_CRITICAL} "nrpc_trace" \
            "'domino cmd trace' timed out - NRPC stack likely wedged"
        PERFDATA+=("nrpc_trace_ms=U;;;0;$((CMD_TIMEOUT*1000))")
        return
    fi
    if [[ ${DOMINO_RC} -ne 0 ]]; then
        record ${STATE_CRITICAL} "nrpc_trace" \
            "'domino cmd' failed (rc=${DOMINO_RC})"
        PERFDATA+=("nrpc_trace_ms=${elapsed}ms;;;0;$((CMD_TIMEOUT*1000))")
        return
    fi

    out=$(extract_cmd_output "$raw")
    if [[ -z "$out" ]]; then
        record ${STATE_CRITICAL} "nrpc_trace" \
            "'trace' produced no output - command queue likely wedged"
        PERFDATA+=("nrpc_trace_ms=${elapsed}ms;;;0;$((CMD_TIMEOUT*1000))")
        return
    fi

    if echo "$out" | grep -qiE "^Connected to server"; then
        local connected_line
        connected_line=$(echo "$out" | grep -iE "^Connected to server" | head -n1)
        record ${STATE_OK} "nrpc_trace" "$connected_line (${elapsed}ms)"
    elif echo "$out" | grep -qiE \
        "unable to find path|server not responding|cannot open|not authorized|Network operation"; then
        local err_line
        err_line=$(echo "$out" | grep -iE \
            "unable to find path|server not responding|cannot open|not authorized|Network operation" \
            | head -n1 | sed 's/^[[:space:]]*//')
        record ${STATE_CRITICAL} "nrpc_trace" "$err_line"
    else
        record ${STATE_WARNING} "nrpc_trace" \
            "trace returned but no clear success/error line (${elapsed}ms)"
    fi
    PERFDATA+=("nrpc_trace_ms=${elapsed}ms;;;0;$((CMD_TIMEOUT*1000))")
}

check_smtp() {
    local start end elapsed banner rc=0
    start=$(now_ms)
    banner=$(timeout "$TIMEOUT" bash -c "
        exec 3<>/dev/tcp/$HOST/$SMTP_PORT || exit 1
        IFS= read -r line <&3
        printf 'QUIT\r\n' >&3
        printf '%s' \"\$line\"
        exec 3<&- 3>&-
    " 2>/dev/null) || rc=$?
    end=$(now_ms); elapsed=$((end - start))

    if [[ $rc -ne 0 || -z "$banner" ]]; then
        record ${STATE_CRITICAL} "smtp" "SMTP port ${SMTP_PORT} did not respond within ${TIMEOUT}s"
        PERFDATA+=("smtp_ms=U;;;0;$((TIMEOUT*1000))")
        return
    fi

    if [[ "$banner" =~ ^220[[:space:]] ]]; then
        if [[ "$banner" == *"Domino"* || "$banner" == *"Lotus"* ]]; then
            record ${STATE_OK} "smtp" "SMTP banner OK (${elapsed}ms): ${banner:0:80}"
        else
            record ${STATE_WARNING} "smtp" "SMTP responded but banner not Domino: ${banner:0:80}"
        fi
    elif [[ "$banner" =~ ^421[[:space:]] ]]; then
        record ${STATE_CRITICAL} "smtp" "SMTP unavailable (421): ${banner:0:80}"
    else
        record ${STATE_CRITICAL} "smtp" "SMTP port open but no valid 220 banner: ${banner:0:80}"
    fi
    PERFDATA+=("smtp_ms=${elapsed}ms;;;0;$((TIMEOUT*1000))")
}

check_http() {
    local start end elapsed http_code body tmpfile rc=0
    tmpfile=$(mktemp)
    start=$(now_ms)
    http_code=$(curl --silent --show-error --max-time "$TIMEOUT" \
                     --output "$tmpfile" \
                     --write-out "%{http_code}" \
                     "$HTTP_URL" 2>/dev/null) || rc=$?
    end=$(now_ms); elapsed=$((end - start))
    body=$(cat "$tmpfile" 2>/dev/null) || true
    rm -f "$tmpfile"

    if [[ $rc -ne 0 ]]; then
        record ${STATE_CRITICAL} "http" "HTTP task did not respond within ${TIMEOUT}s (${HTTP_URL})"
        PERFDATA+=("http_ms=U;;;0;$((TIMEOUT*1000))")
        return
    fi

    if [[ "$http_code" =~ ^2 ]]; then
        if [[ -n "$HTTP_EXPECT" && "$body" != *"$HTTP_EXPECT"* ]]; then
            record ${STATE_WARNING} "http" \
                "HTTP ${http_code} but body missing '${HTTP_EXPECT}' (${elapsed}ms)"
        else
            record ${STATE_OK} "http" "HTTP ${http_code} (${elapsed}ms)"
        fi
    elif [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
        record ${STATE_OK} "http" "HTTP ${http_code} - HTTP task responding (${elapsed}ms)"
    else
        record ${STATE_CRITICAL} "http" "HTTP ${http_code} from ${HTTP_URL} (${elapsed}ms)"
    fi
    PERFDATA+=("http_ms=${elapsed}ms;;;0;$((TIMEOUT*1000))")
}

(( CHECK_STATUS ))         && check_status
(( CHECK_NRPC_TCP ))       && check_nrpc_tcp
(( CHECK_NRPC_HANDSHAKE )) && check_nrpc_handshake
(( CHECK_SHOW_SERVER ))    && check_show_server
(( CHECK_NRPC_TRACE ))     && check_nrpc_trace
(( CHECK_SMTP ))           && check_smtp
(( CHECK_HTTP ))           && check_http

case $STATUS in
    "${STATE_OK}")       LABEL="OK"       ;;
    "${STATE_WARNING}")  LABEL="WARNING"  ;;
    "${STATE_CRITICAL}") LABEL="CRITICAL" ;;
    *)                   LABEL="UNKNOWN"  ;;
esac

echo "${PLUGIN_NAME} ${LABEL} - ${SUMMARY[*]} | ${PERFDATA[*]}"
for d in "${DETAILS[@]}"; do echo "$d"; done

exit "${STATUS}"
