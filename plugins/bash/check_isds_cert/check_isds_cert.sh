#!/usr/bin/env bash
# MIT License
# Copyright (c) 2025 ISW Kudos
# https://github.com/isw-kudos/icinga-plugins/blob/main/LICENSE
#
# check_isds_cert - Icinga/Nagios plugin for IBM Security Directory Server
#
# Monitors TLS certificate expiry inside the GSKit CMS keystore (.kdb) used by
# IBM Security Directory Server (SDS, formerly IBM Tivoli Directory Server, now
# IBM Security Verify Directory). Runs LOCALLY on the SDS host using the bundled
# GSKit cert tool to read the keystore, parse each certificate's "not after"
# validity date, and alert before a cert expires and breaks LDAPS.
#
# Source: a GSKit CMS keystore (.kdb), unlocked via its stash file (.sth) so no
# password is exposed on the command line.
#
# NOTE: the exact field wording in `gsk*capicmd -cert -details` output varies by
# GSKit version (e.g. "Not After", "Valid To", "validTo"). The regex that picks
# the not-after line is in the clearly-marked "Validity field matching" block
# below - adjust it there if your GSKit prints a different label.
#
# Exit codes: 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN
#

set -euo pipefail

PLUGIN_NAME="check_isds_cert"
PLUGIN_VERSION="1.0.0"

# ---------- Defaults ----------
KDB=""
STASH=""
PASSWORD=""
LABEL=""

WARN_DAYS=30
CRIT_DAYS=7

TIMEOUT=30

# ---------- Validity field matching (adjust per GSKit version if needed) ----------
# Lines from `gsk*capicmd -cert -details` describing the expiry date. Different
# GSKit builds use different labels; this regex (case-insensitive) matches any of
# them. The captured remainder of the line is then handed to GNU `date -d`.
NOT_AFTER_REGEX='^[[:space:]]*(not[[:space:]]*after|valid[[:space:]]*to|validity[[:space:]]*to|notafter|validto)[[:space:]]*:'

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
Usage: ${PLUGIN_NAME} --kdb PATH [--stash PATH | --password PW] [--label LABEL] \\
                      [-w DAYS] [-c DAYS] [-t SECONDS] [-V] [-h]

Keystore:
  --kdb PATH             Path to the GSKit CMS keystore (.kdb) (required)
  --stash PATH           Path to the .sth stash file (preferred; uses -stashed)
  --password PW          Keystore password (DISCOURAGED - visible in process list)
  --label LABEL          Check only this certificate label. If omitted, ALL certs
                         in the keystore are checked and the soonest to expire is
                         reported.

Thresholds:
  -w DAYS                Warn when a cert expires within DAYS days (default: ${WARN_DAYS})
  -c DAYS                Crit when a cert expires within DAYS days (default: ${CRIT_DAYS})

General:
  -t SECONDS             Timeout (default: ${TIMEOUT})
  -V, --version          Show version
  -h, --help             Show this help

Exit codes: 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --kdb) KDB="$2"; shift 2 ;;
        --stash) STASH="$2"; shift 2 ;;
        --password) PASSWORD="$2"; shift 2 ;;
        --label) LABEL="$2"; shift 2 ;;
        -w) WARN_DAYS="$2"; shift 2 ;;
        -c) CRIT_DAYS="$2"; shift 2 ;;
        -t) TIMEOUT="$2"; shift 2 ;;
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

# Locate the GSKit CMS cert tool: prefer the 64-bit capicmd, then 32-bit, then the
# SDS-bundled idsgskcapicmd wrapper.
GSK_BIN=""
find_gsk() {
    local c
    for c in gsk8capicmd_64 gsk8capicmd idsgskcapicmd; do
        if command -v "$c" >/dev/null 2>&1; then
            GSK_BIN="$c"
            return 0
        fi
    done
    return 1
}

# run_gsk <args...>
# Runs the GSKit tool with keystore access flags appended (-db + -stashed/-pw),
# sets global GSK_OUT to combined stdout/stderr, and returns the tool exit code.
# Must NOT be called via command substitution, or GSK_OUT would be set in a
# subshell and the return code would be that of the substitution, not the tool.
GSK_OUT=""
run_gsk() {
    local args=("$@")
    args+=(-db "$KDB")
    if [[ -n "$STASH" ]]; then
        args+=(-stashed)
    elif [[ -n "$PASSWORD" ]]; then
        args+=(-pw "$PASSWORD")
    else
        args+=(-stashed)
    fi

    local rc=0
    GSK_OUT=$(timeout --kill-after=2 "$TIMEOUT" "$GSK_BIN" "${args[@]}" 2>&1) || rc=$?
    return "$rc"
}

# sanitize <label> -> perfdata-safe key (alnum/underscore only)
sanitize() {
    local s=$1
    s=$(printf '%s' "$s" | tr -c '[:alnum:]' '_')
    s=$(printf '%s' "$s" | sed 's/__*/_/g; s/^_//; s/_$//')
    [[ -z "$s" ]] && s="cert"
    printf '%s' "$s"
}

# parse_labels <gsk -cert -list output> -> one label per line
# `gsk*capicmd -cert -list` prints a header then indented lines, one per cert
# label. Some builds prefix entries with a "*" marker for the default cert; we
# strip leading markers/whitespace and skip the header line(s).
parse_labels() {
    printf '%s\n' "$1" | sed -n 's/^[[:space:]]*[*!-]\{0,1\}[[:space:]]*//p' \
        | grep -v -i -E '^(certificates|certificate|keys?)[[:space:]]+(found|in)' \
        | grep -v -E '^[[:space:]]*$' || true
}

# extract_not_after <gsk -cert -details output> -> raw date string after the label
extract_not_after() {
    printf '%s\n' "$1" | grep -i -E "$NOT_AFTER_REGEX" | head -n1 \
        | sed -E 's/^[^:]*:[[:space:]]*//'
}

# Globals populated by check_label
MIN_DAYS=""
SOONEST_LABEL=""

# check_label <label>
# Reads the cert details, computes days-until-expiry, emits perfdata, and tracks
# the soonest-expiring cert seen so far.
check_label() {
    local label=$1
    local key
    key=$(sanitize "$label")

    local rc=0
    run_gsk -cert -details -label "$label" || rc=$?

    if [[ ${rc} -eq 124 || ${rc} -eq 137 ]]; then
        record "${STATE_CRITICAL}" "${key}" "gsk timed out reading label '${label}' after ${TIMEOUT}s"
        PERFDATA+=("days_until_expiry_${key}=U")
        return
    fi
    if [[ ${rc} -ne 0 ]]; then
        record "${STATE_UNKNOWN}" "${key}" "gsk failed for label '${label}' (rc=${rc}): $(printf '%s' "$GSK_OUT" | tail -n1)"
        PERFDATA+=("days_until_expiry_${key}=U")
        return
    fi

    local raw_date
    raw_date=$(extract_not_after "$GSK_OUT")
    if [[ -z "$raw_date" ]]; then
        record "${STATE_UNKNOWN}" "${key}" "could not find expiry date for label '${label}' (adjust NOT_AFTER_REGEX)"
        PERFDATA+=("days_until_expiry_${key}=U")
        return
    fi

    local exp_epoch now_epoch days
    if ! exp_epoch=$(date -d "$raw_date" +%s 2>/dev/null); then
        record "${STATE_UNKNOWN}" "${key}" "could not parse expiry date '${raw_date}' for label '${label}'"
        PERFDATA+=("days_until_expiry_${key}=U")
        return
    fi
    now_epoch=$(date +%s)
    days=$(( (exp_epoch - now_epoch) / 86400 ))

    PERFDATA+=("days_until_expiry_${key}=${days};${WARN_DAYS}:;${CRIT_DAYS}:;;")

    # Track soonest-expiring cert across all labels checked.
    if [[ -z "$MIN_DAYS" ]] || (( days < MIN_DAYS )); then
        MIN_DAYS=$days
        SOONEST_LABEL=$label
    fi

    local lvl detail
    if (( days < 0 )); then
        lvl=${STATE_CRITICAL}
        detail="'${label}' EXPIRED $(( -days )) days ago"
    elif (( days <= CRIT_DAYS )); then
        lvl=${STATE_CRITICAL}
        detail="'${label}' expires in ${days} days"
    elif (( days <= WARN_DAYS )); then
        lvl=${STATE_WARNING}
        detail="'${label}' expires in ${days} days"
    else
        lvl=${STATE_OK}
        detail="'${label}' expires in ${days} days"
    fi
    record "$lvl" "${key}" "$detail"
}

main() {
    if ! find_gsk; then
        record "${STATE_UNKNOWN}" "cert" "No GSKit cert tool found in PATH (looked for gsk8capicmd_64, gsk8capicmd, idsgskcapicmd)"
        return
    fi

    if [[ ! -r "$KDB" ]]; then
        record "${STATE_UNKNOWN}" "cert" "Keystore not readable: ${KDB}"
        return
    fi
    if [[ -n "$STASH" && ! -r "$STASH" ]]; then
        record "${STATE_UNKNOWN}" "cert" "Stash file not readable: ${STASH}"
        return
    fi

    local labels=()
    if [[ -n "$LABEL" ]]; then
        labels=("$LABEL")
    else
        local rc=0
        run_gsk -cert -list || rc=$?
        if [[ ${rc} -eq 124 || ${rc} -eq 137 ]]; then
            record "${STATE_CRITICAL}" "cert" "gsk -cert -list timed out after ${TIMEOUT}s"
            return
        fi
        if [[ ${rc} -ne 0 ]]; then
            record "${STATE_UNKNOWN}" "cert" "gsk -cert -list failed (rc=${rc}): $(printf '%s' "$GSK_OUT" | tail -n1)"
            return
        fi
        local line
        while IFS= read -r line; do
            [[ -n "$line" ]] && labels+=("$line")
        done < <(parse_labels "$GSK_OUT")
        if [[ ${#labels[@]} -eq 0 ]]; then
            record "${STATE_UNKNOWN}" "cert" "no certificate labels found in keystore ${KDB}"
            return
        fi
    fi

    local l
    for l in "${labels[@]}"; do
        check_label "$l"
    done

    if [[ -n "$MIN_DAYS" ]]; then
        PERFDATA+=("min_days_until_expiry=${MIN_DAYS};${WARN_DAYS}:;${CRIT_DAYS}:;;")
        local verb="expires in ${MIN_DAYS} days"
        (( MIN_DAYS < 0 )) && verb="EXPIRED $(( -MIN_DAYS )) days ago"
        record "${STATE_OK}" "soonest" "'${SOONEST_LABEL}' ${verb}"
    fi
}

if [[ -z "$KDB" ]]; then
    echo "${PLUGIN_NAME} UNKNOWN - Keystore path is required (--kdb PATH)"
    exit "${STATE_UNKNOWN}"
fi

main

case $STATUS in
    "${STATE_OK}")       LABEL_OUT="OK"       ;;
    "${STATE_WARNING}")  LABEL_OUT="WARNING"  ;;
    "${STATE_CRITICAL}") LABEL_OUT="CRITICAL" ;;
    *)                   LABEL_OUT="UNKNOWN"  ;;
esac

if [[ ${#PERFDATA[@]} -gt 0 ]]; then
    echo "${PLUGIN_NAME} ${LABEL_OUT} - ${SUMMARY[*]} | ${PERFDATA[*]}"
else
    echo "${PLUGIN_NAME} ${LABEL_OUT} - ${SUMMARY[*]}"
fi
for d in "${DETAILS[@]}"; do echo "$d"; done

exit "${STATUS}"
