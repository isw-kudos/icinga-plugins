#!/usr/bin/env bash
# MIT License
# Copyright (c) 2025 ISW Kudos
# https://github.com/isw-kudos/icinga-plugins/blob/main/LICENSE
#
# check_cnx_docs - Icinga/Nagios plugin for HCL Connections Docs
# Conversion servers (Symphony / LibreOffice stack)
#
# Sub-checks:
#   1. sym_monitor - the sym_monitor watchdog process is running
#   2. soffice     - soffice worker count matches the expected count
#                    autodetected from instances.cfg (one non-empty line
#                    per expected instance)
#
# Exit codes: 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN
#

set -euo pipefail

PLUGIN_NAME="check_cnx_docs"
PLUGIN_VERSION="1.0.0"

# ---------- Defaults ----------
INSTANCES_CFG="/opt/Conversion/symphony/sym_monitor/instances.cfg"
SYM_MONITOR_PATTERN="sym_monitor"
SOFFICE_PATTERN="soffice"
SYM_MONITOR_GRACE=300
STATE_FILE="/tmp/check_cnx_docs.state"
TIMEOUT=30

CHECK_SYM_MONITOR=1
CHECK_SOFFICE=1

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

Checks HCL Connections Docs Conversion servers.

Sub-checks:
  sym_monitor   sym_monitor watchdog process is running
  soffice       soffice worker count matches expected count autodetected
                from instances.cfg (one non-empty line per expected
                instance)

Options:
  --instances-cfg PATH             Path to instances.cfg
                                   (default: ${INSTANCES_CFG})
  --sym-monitor-pattern PAT        pgrep -f pattern for sym_monitor
                                   (default: ${SYM_MONITOR_PATTERN})
  --soffice-pattern PAT            pgrep -f pattern for soffice
                                   (default: ${SOFFICE_PATTERN})
  --sym-monitor-grace-seconds N    Suppress CRITICAL while sym_monitor has
                                   been down for <= N seconds (covers the
                                   cron-driven restart window). Set to 0
                                   to disable. (default: ${SYM_MONITOR_GRACE})
  --state-file PATH                Path to state file used to track first
                                   time sym_monitor was seen down.
                                   (default: ${STATE_FILE})
  -t SECONDS                       Per-operation timeout (default: ${TIMEOUT})

Sub-check toggles:
  --no-sym-monitor                 Disable the sym_monitor sub-check
  --no-soffice                     Disable the soffice sub-check

  -V, --version                    Show version
  -h, --help                       Show this help

Exit codes: 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --instances-cfg)              INSTANCES_CFG="$2"; shift 2 ;;
        --sym-monitor-pattern)        SYM_MONITOR_PATTERN="$2"; shift 2 ;;
        --soffice-pattern)            SOFFICE_PATTERN="$2"; shift 2 ;;
        --sym-monitor-grace-seconds)  SYM_MONITOR_GRACE="$2"; shift 2 ;;
        --state-file)                 STATE_FILE="$2"; shift 2 ;;
        --no-sym-monitor)             CHECK_SYM_MONITOR=0; shift ;;
        --no-soffice)                 CHECK_SOFFICE=0; shift ;;
        -t|--timeout)                 TIMEOUT="$2"; shift 2 ;;
        -V|--version)                 echo "${PLUGIN_NAME} v${PLUGIN_VERSION}"; exit "${STATE_OK}" ;;
        -h|--help)                    usage; exit "${STATE_UNKNOWN}" ;;
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
    DETAILS+=("[$tag] ${short}: $detail")
    escalate "$lvl"
}

# count_procs PATTERN
# Counts processes whose full command line matches PATTERN (pgrep -fc).
# Writes results to globals so the caller is not a $() subshell — that
# would otherwise swallow the rc. Treats pgrep exit 1 ("no matches") as
# count=0. COUNT_PROCS_RC is 0 on success, 124/137 on timeout, or the
# pgrep rc on other failures.
#
# The pattern is passed to pgrep via an environment variable so it never
# appears in the argv of `timeout` or `sh` — otherwise `pgrep -f` would
# match its own ancestor processes (their argv contains the pattern as
# a literal string) and double-count by one per call.
COUNT_PROCS_OUT=0
COUNT_PROCS_RC=0
count_procs() {
    local pattern=$1 out rc=0
    COUNT_PROCS_OUT=0
    COUNT_PROCS_RC=0
    # shellcheck disable=SC2016
    # Single quotes intentional: $CNX_DOCS_PGREP_PATTERN must expand inside
    # the inner `sh -c`, not in the outer shell — that's the whole point
    # of passing it via env (see comment above).
    out=$(CNX_DOCS_PGREP_PATTERN="$pattern" \
        timeout --kill-after=2 "${TIMEOUT}" \
        sh -c 'exec pgrep -fc -- "$CNX_DOCS_PGREP_PATTERN"' 2>/dev/null) || rc=$?
    if [[ $rc -eq 124 || $rc -eq 137 ]]; then
        COUNT_PROCS_RC=$rc
        return
    fi
    if [[ $rc -eq 1 ]]; then
        # pgrep -c exits 1 when no matches; the count "0" is already on stdout
        COUNT_PROCS_OUT="${out:-0}"
        return
    fi
    if [[ $rc -ne 0 ]]; then
        COUNT_PROCS_RC=$rc
        return
    fi
    COUNT_PROCS_OUT="${out:-0}"
}

# read_state_epoch
# Echoes the epoch stored in STATE_FILE if it's a positive integer.
# Echoes "" otherwise (missing, unreadable, or corrupt).
read_state_epoch() {
    [[ -r "$STATE_FILE" ]] || { echo ""; return; }
    local v
    v=$(tr -d '[:space:]' < "$STATE_FILE" 2>/dev/null) || { echo ""; return; }
    [[ "$v" =~ ^[0-9]+$ ]] || { echo ""; return; }
    echo "$v"
}

# write_state_epoch EPOCH -> rc 0 on success, 1 on failure
write_state_epoch() {
    # Subshell so bash's own redirect-failure message goes to /dev/null too,
    # not just printf's stderr.
    ( printf '%s\n' "$1" > "$STATE_FILE" ) 2>/dev/null
}

clear_state() { rm -f "$STATE_FILE" 2>/dev/null || true; }

check_sym_monitor() {
    count_procs "$SYM_MONITOR_PATTERN"
    if [[ $COUNT_PROCS_RC -eq 124 || $COUNT_PROCS_RC -eq 137 ]]; then
        record "${STATE_UNKNOWN}" "sym_monitor" "pgrep timed out after ${TIMEOUT}s"
        PERFDATA+=("sym_monitor_procs=U")
        PERFDATA+=("sym_monitor_down_seconds=U")
        return
    fi
    if [[ $COUNT_PROCS_RC -ne 0 ]]; then
        record "${STATE_UNKNOWN}" "sym_monitor" "pgrep failed (rc=${COUNT_PROCS_RC})"
        PERFDATA+=("sym_monitor_procs=U")
        PERFDATA+=("sym_monitor_down_seconds=U")
        return
    fi

    local n=$COUNT_PROCS_OUT
    if (( n > 0 )); then
        clear_state
        record "${STATE_OK}" "sym_monitor" "${n} process(es) running"
        PERFDATA+=("sym_monitor_procs=${n}")
        PERFDATA+=("sym_monitor_down_seconds=0;${SYM_MONITOR_GRACE};${SYM_MONITOR_GRACE};0")
        return
    fi

    # sym_monitor is down. Apply grace window from state file so a
    # cron-driven restart within SYM_MONITOR_GRACE seconds doesn't page.
    local now first_down down_s state_note=""
    now=$(date +%s)
    first_down=$(read_state_epoch)
    if [[ -z "$first_down" ]]; then
        first_down=$now
        if ! write_state_epoch "$first_down"; then
            state_note=" (could not write ${STATE_FILE} - grace disabled)"
            down_s=$((SYM_MONITOR_GRACE + 1))   # force CRITICAL
        fi
    fi
    if [[ -z "${down_s:-}" ]]; then
        down_s=$(( now - first_down ))
        (( down_s < 0 )) && down_s=0   # clock skew safety
    fi

    # grace > 0 enables suppression; grace == 0 means "no grace, alert now".
    if (( SYM_MONITOR_GRACE > 0 && down_s <= SYM_MONITOR_GRACE )); then
        record "${STATE_OK}" "sym_monitor" \
            "no process found, down for ${down_s}s (within ${SYM_MONITOR_GRACE}s grace - cron restart pending)${state_note}"
    else
        record "${STATE_CRITICAL}" "sym_monitor" \
            "no process matching '${SYM_MONITOR_PATTERN}' found, down for ${down_s}s (exceeded ${SYM_MONITOR_GRACE}s grace)${state_note}"
    fi
    PERFDATA+=("sym_monitor_procs=0")
    PERFDATA+=("sym_monitor_down_seconds=${down_s};${SYM_MONITOR_GRACE};${SYM_MONITOR_GRACE};0")
}

check_soffice() {
    local expected actual rc=0

    if [[ ! -e "$INSTANCES_CFG" ]]; then
        record "${STATE_UNKNOWN}" "soffice" \
            "instances.cfg not found at ${INSTANCES_CFG} - cannot determine expected count"
        PERFDATA+=("soffice_procs=U")
        PERFDATA+=("soffice_expected=U")
        return
    fi
    if [[ ! -r "$INSTANCES_CFG" ]]; then
        record "${STATE_UNKNOWN}" "soffice" \
            "instances.cfg at ${INSTANCES_CFG} is not readable by $(id -un) - check file permissions"
        PERFDATA+=("soffice_procs=U")
        PERFDATA+=("soffice_expected=U")
        return
    fi

    # Count non-empty lines in instances.cfg (robust to trailing newlines
    # and stray blank lines). grep -c exit 1 means "no matching lines".
    expected=$(timeout --kill-after=2 "${TIMEOUT}" \
        grep -c '[^[:space:]]' "$INSTANCES_CFG" 2>/dev/null) || rc=$?
    if [[ $rc -eq 124 || $rc -eq 137 ]]; then
        record "${STATE_UNKNOWN}" "soffice" \
            "reading instances.cfg timed out after ${TIMEOUT}s"
        PERFDATA+=("soffice_procs=U")
        PERFDATA+=("soffice_expected=U")
        return
    fi
    if [[ $rc -eq 1 ]]; then
        expected=0
    elif [[ $rc -ne 0 ]]; then
        record "${STATE_UNKNOWN}" "soffice" \
            "grep on instances.cfg failed (rc=${rc})"
        PERFDATA+=("soffice_procs=U")
        PERFDATA+=("soffice_expected=U")
        return
    fi

    if (( expected == 0 )); then
        record "${STATE_UNKNOWN}" "soffice" \
            "instances.cfg has zero non-empty lines - Symphony likely misconfigured"
        PERFDATA+=("soffice_procs=U")
        PERFDATA+=("soffice_expected=0")
        return
    fi

    count_procs "$SOFFICE_PATTERN"
    if [[ $COUNT_PROCS_RC -eq 124 || $COUNT_PROCS_RC -eq 137 ]]; then
        record "${STATE_UNKNOWN}" "soffice" "pgrep timed out after ${TIMEOUT}s"
        PERFDATA+=("soffice_procs=U;${expected};;")
        PERFDATA+=("soffice_expected=${expected}")
        return
    fi
    if [[ $COUNT_PROCS_RC -ne 0 ]]; then
        record "${STATE_UNKNOWN}" "soffice" "pgrep failed (rc=${COUNT_PROCS_RC})"
        PERFDATA+=("soffice_procs=U;${expected};;")
        PERFDATA+=("soffice_expected=${expected}")
        return
    fi
    actual=$COUNT_PROCS_OUT

    if (( actual == 0 )); then
        record "${STATE_CRITICAL}" "soffice" \
            "0 of ${expected} expected processes running (from instances.cfg)"
    elif (( actual < expected )); then
        record "${STATE_WARNING}" "soffice" \
            "${actual} of ${expected} expected processes running (from instances.cfg)"
    elif (( actual > expected )); then
        record "${STATE_OK}" "soffice" \
            "${actual} processes running, ${expected} expected (extra instance running)"
    else
        record "${STATE_OK}" "soffice" \
            "${actual} of ${expected} expected processes running (from instances.cfg)"
    fi
    PERFDATA+=("soffice_procs=${actual};${expected};;")
    PERFDATA+=("soffice_expected=${expected}")
}

(( CHECK_SYM_MONITOR )) && check_sym_monitor
(( CHECK_SOFFICE ))     && check_soffice

if (( ${#SUMMARY[@]} == 0 )); then
    echo "${PLUGIN_NAME} UNKNOWN - No sub-checks enabled"
    exit "${STATE_UNKNOWN}"
fi

case $STATUS in
    "${STATE_OK}")       LABEL="OK"       ;;
    "${STATE_WARNING}")  LABEL="WARNING"  ;;
    "${STATE_CRITICAL}") LABEL="CRITICAL" ;;
    *)                   LABEL="UNKNOWN"  ;;
esac

echo "${PLUGIN_NAME} ${LABEL} - ${SUMMARY[*]} | ${PERFDATA[*]}"
for d in "${DETAILS[@]}"; do echo "$d"; done

exit "${STATUS}"
