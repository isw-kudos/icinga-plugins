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
PLUGIN_VERSION="1.1.1"

# ---------- Defaults ----------
KDB=""
STASH=""
PASSWORD=""
LABEL=""
# By default only PERSONAL certs (those with a private key - what the server
# actually presents) are checked. A keystore usually also holds the bundled CA
# roots, several of which may be long expired; --all-certs opts into those too.
CHECK_ALL_CERTS=0
# --gsk-bin: absolute path to the GSKit cert tool (else searched on PATH and under
# common GSKit install dirs).
GSK_OVERRIDE=""

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
  --label LABEL          Check only this certificate label. If omitted, all
                         PERSONAL certs are checked and the soonest is reported.
  --all-certs            Check every cert incl. trusted CA roots (default: personal
                         certs only, so expired bundled CA roots do not alert).
  --gsk-bin PATH         Path to gsk8capicmd_64/idsgskcapicmd (else searched on PATH
                         and under /opt/db2/*/gskit/bin, /usr/local/ibm/gsk8*/bin, …)

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
        --all-certs) CHECK_ALL_CERTS=1; shift ;;
        --gsk-bin) GSK_OVERRIDE="$2"; shift 2 ;;
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

# Locate the GSKit CMS cert tool. Honors --gsk-bin; otherwise searches PATH then
# common GSKit install dirs (it is usually off the icinga user's PATH - e.g. the
# DB2-bundled GSKit under /opt/db2/*/gskit/bin).
GSK_BIN=""
find_gsk() {
    if [[ -n "$GSK_OVERRIDE" ]]; then
        if [[ -x "$GSK_OVERRIDE" ]]; then
            GSK_BIN="$GSK_OVERRIDE"
        elif command -v "$GSK_OVERRIDE" >/dev/null 2>&1; then
            GSK_BIN=$(command -v "$GSK_OVERRIDE")
        else
            return 1
        fi
        return 0
    fi
    local c d
    for c in gsk8capicmd_64 gsk8capicmd idsgskcapicmd; do
        if command -v "$c" >/dev/null 2>&1; then
            GSK_BIN=$(command -v "$c"); return 0
        fi
    done
    for d in /opt/db2/*/gskit/bin /usr/local/ibm/gsk8_64/bin /usr/local/ibm/gsk8/bin \
             /opt/ibm/gsk8_64/bin /opt/IBM/ldap/*/bin; do
        if [[ -x "$d/gsk8capicmd_64" ]]; then GSK_BIN="$d/gsk8capicmd_64"; return 0; fi
        if [[ -x "$d/gsk8capicmd" ]]; then GSK_BIN="$d/gsk8capicmd"; return 0; fi
    done
    return 1
}

# run_gsk <args...>
# Runs the GSKit tool with keystore access flags appended (-db + -stashed/-pw),
# sets global GSK_OUT to combined stdout/stderr, and returns the tool exit code.
# Must NOT be called via command substitution, or GSK_OUT would be set in a
# subshell and the return code would be that of the substitution, not the tool.
# Sets LD_LIBRARY_PATH to the tool's GSKit lib dir so it resolves when the binary
# is off-PATH and the icinga user lacks the GSKit ld.so config.
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

    local root envp=()
    root=$(dirname "$(dirname "$GSK_BIN")")
    if [[ -d "$root/lib64" ]]; then
        envp=(env "LD_LIBRARY_PATH=$root/lib64:${LD_LIBRARY_PATH:-}")
    elif [[ -d "$root/lib" ]]; then
        envp=(env "LD_LIBRARY_PATH=$root/lib:${LD_LIBRARY_PATH:-}")
    fi

    local rc=0
    GSK_OUT=$(timeout --kill-after=2 "$TIMEOUT" \
        ${envp[@]+"${envp[@]}"} "$GSK_BIN" "${args[@]}" 2>&1) || rc=$?
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

# parse_labels <gsk -cert -list output> -> one cert label per line.
# `gsk*capicmd -cert -list <type>` prints a header + legend then one line per cert:
#   <flags>\t<label>     where flags are from: * default, - personal, ! trusted,
#   # secret key. The label is bare when it has no spaces (e.g. ldap.ams.cloud) and
#   double-quoted when it contains spaces (e.g. CA names). Personal/CA filtering is
#   done by the gsk `-cert -list personal|all` type, so this just extracts labels:
#   strip the leading flags + whitespace, then unwrap surrounding quotes if present.
#   The header ("Certificates found") and legend line are skipped.
parse_labels() {
    printf '%s\n' "$1" | awk '
        /^Certificates found/        { next }
        /personal,[[:space:]]*!?[[:space:]]*trusted/ { next }   # legend line
        {
            line = $0
            sub(/^[[:space:]]*[*!#-]+[[:space:]]+/, "", line)   # drop leading flags
            sub(/[[:space:]]+$/, "", line)
            if (line == "") next
            if (substr(line, 1, 1) == "\"") {
                line = substr(line, 2)
                q = index(line, "\"")
                if (q > 0) line = substr(line, 1, q - 1)
            }
            if (line != "") print line
        }'
}

# gsk_date_to_epoch <gsk date string> -> epoch seconds (stdout), or non-zero.
# GSKit -cert -details prints e.g. "2040 11 24 10:41:54 GMT+01:00": space-separated
# YYYY M D (no zero-padding) HH:MM:SS [tz]. Reformat to ISO for GNU `date`. The tz
# is ignored - irrelevant at day granularity. Returns non-zero if not that shape
# (so the caller can fall back to feeding the raw string to `date -d`).
gsk_date_to_epoch() {
    local y mo d t
    read -r y mo d t _ <<<"$1"
    [[ "$y" =~ ^[0-9]{4}$ && "$mo" =~ ^[0-9]{1,2}$ && "$d" =~ ^[0-9]{1,2}$ ]] || return 1
    local iso
    printf -v iso '%04d-%02d-%02d %s' "$y" "$mo" "$d" "${t:-00:00:00}"
    date -d "$iso" +%s 2>/dev/null
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
    # GSKit's "YYYY M D HH:MM:SS" format first; fall back to whatever `date -d`
    # understands for other GSKit builds.
    if ! exp_epoch=$(gsk_date_to_epoch "$raw_date") || [[ -z "$exp_epoch" ]]; then
        if ! exp_epoch=$(date -d "$raw_date" +%s 2>/dev/null); then
            record "${STATE_UNKNOWN}" "${key}" "could not parse expiry date '${raw_date}' for label '${label}'"
            PERFDATA+=("days_until_expiry_${key}=U")
            return
        fi
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
        # Let GSKit filter by cert type: "personal" (default - the certs the server
        # presents) or "all" (incl. trusted CA roots) with --all-certs.
        local list_type="personal"
        (( CHECK_ALL_CERTS )) && list_type="all"
        local rc=0
        run_gsk -cert -list "$list_type" || rc=$?
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
            if [[ "$list_type" == "personal" ]]; then
                record "${STATE_UNKNOWN}" "cert" "no personal certificate found in keystore ${KDB} (use --label or --all-certs)"
            else
                record "${STATE_UNKNOWN}" "cert" "no certificate labels found in keystore ${KDB}"
            fi
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
