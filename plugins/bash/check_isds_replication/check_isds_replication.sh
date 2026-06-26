#!/usr/bin/env bash
# MIT License
# Copyright (c) 2025 ISW Kudos
# https://github.com/isw-kudos/icinga-plugins/blob/main/LICENSE
#
# check_isds_replication - Icinga/Nagios plugin for IBM Security Directory Server
#
# Monitors replication health of an IBM Security Directory Server (SDS, formerly
# IBM Tivoli Directory Server, now IBM Security Verify Directory) over LDAP by
# enumerating replication agreement entries and inspecting their status:
#
#   1. state          - alerts CRITICAL when an agreement is suspended, on hold
#                        or in an error state.
#   2. last result    - alerts CRITICAL when the last replication result code is
#                        a non-zero numeric LDAP result.
#   3. pending changes - WARN/CRIT on the per-agreement queued change backlog
#                        (ibm-replicationPendingChangeCount) using -w/-c.
#   4. lag (optional) - age of the last replicated change, derived from a
#                        generalized timestamp, compared to --lag-warn/--lag-crit.
#
# Designed to run locally on the SDS host using the bundled idsldapsearch, but
# falls back to a standard ldapsearch and works remotely too.
#
# NOTE: Replication agreement attribute names and their meaning vary across
# SDS/ISVD versions. The expected names are defined in the "Attribute names"
# block below - adjust them there if a status attribute reports as not found.
# In particular ibm-replicationChangeLastResultTime is version-dependent; the
# optional lag check is disabled unless --lag-warn/--lag-crit are supplied.
#
# Exit codes: 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN
#

set -euo pipefail

PLUGIN_NAME="check_isds_replication"
PLUGIN_VERSION="1.1.0"

# ---------- Defaults ----------
HOST="127.0.0.1"
PORT=389
USE_LDAPS=0
USE_STARTTLS=0
BINDDN=""
BINDPW=""
BINDPW_FILE=""

# LDAP client selection. The plugin auto-detects whether the client uses IBM
# (idsldapsearch: -h/-p/-L/-w) or OpenLDAP (ldapsearch: -H/-x/-LLL/-y) flag
# syntax and builds the right arguments. Override either with the flags below.
LDAPSEARCH_OVERRIDE=""   # --ldapsearch-bin: absolute path to the client binary
LDAP_FLAVOR=""           # --ldap-flavor: force "ibm" or "openldap" (else auto)
KEY_FILE=""              # --key-file: IBM SSL key database (.kdb) for --ldaps
KEY_PW=""                # --key-pw: IBM SSL key database password/stash

# Search base for replication agreements. Empty means "not set" -> UNKNOWN with a
# hint, because there is no universal default suffix.
BASE=""
# Optional sub-base appended onto agreements; empty means search from BASE.
REPL_BASE=""
# Repeatable agreement cn filters; empty array means all agreements.
AGREEMENTS=()

# Pending-change backlog thresholds (per agreement)
PENDING_WARN=100
PENDING_CRIT=1000
# Replication lag thresholds in seconds; empty = disabled
LAG_WARN=""
LAG_CRIT=""

TIMEOUT=30

# ---------- Attribute names (adjust per SDS version if needed) ----------
OC_AGREEMENT="ibm-replicationAgreement"
ATTR_STATE="ibm-replicationState"
ATTR_PENDING="ibm-replicationPendingChangeCount"
ATTR_LAST_RESULT="ibm-replicationLastResult"
ATTR_LAST_RESULT_ADDL="ibm-replicationLastResultAdditional"
ATTR_LAST_CHANGE_ID="ibm-replicationLastChangeId"
# Version-dependent generalized timestamp of the last replicated change result.
ATTR_LAST_RESULT_TIME="ibm-replicationChangeLastResultTime"

# State values that indicate the agreement is not actively/healthily replicating.
# Compared case-insensitively as substrings of ibm-replicationState.
ERROR_STATES=(
    "suspend"
    "on hold"
    "onhold"
    "hold"
    "error"
    "binding"
    "retrying"
    "waiting"
)

STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3

STATUS=${STATE_OK}
SUMMARY=()
DETAILS=()
PERFDATA=()

AGREEMENTS_OK=0
AGREEMENTS_ERROR=0

usage() {
    cat <<EOF
Usage: ${PLUGIN_NAME} [options]

Connection:
  -H HOST                LDAP host/IP (default: ${HOST})
  -p PORT                LDAP port (default: ${PORT})
  --ldaps                Use ldaps:// (implies the LDAPS port; set -p too)
  -Z                     Use StartTLS on the plain port
  -D BINDDN              Bind DN (e.g. a read-only replication monitor account)
  -W PASSWORD            Bind password (discouraged - visible in process list)
  -y PASSWORD_FILE       Read bind password from first line of file (preferred)

LDAP client:
  --ldapsearch-bin PATH  Absolute path to idsldapsearch/ldapsearch (else searched
                         on PATH and under /opt/*/ldap/*/bin)
  --ldap-flavor FLAVOR   Force "ibm" or "openldap" flag syntax (else auto-detected)
  --key-file PATH        IBM SSL key database (.kdb) - used with --ldaps (IBM)
  --key-pw PASS          IBM SSL key database password/stash - used with --ldaps

Search:
  -b, --base DN          Search base for replication agreements (required)
  --repl-base DN         Optional sub-tree under -b to search (default: from base)
  --agreement CN         Only check the agreement with this cn (repeatable)

Thresholds:
  -w N                   Warn when pending changes >= N (default: ${PENDING_WARN})
  -c N                   Crit when pending changes >= N (default: ${PENDING_CRIT})
  --lag-warn SECONDS     Warn when last-change age >= SECONDS (default: off)
  --lag-crit SECONDS     Crit when last-change age >= SECONDS (default: off)

General:
  -t SECONDS             Timeout (default: ${TIMEOUT})
  -V, --version          Show version
  -h, --help             Show this help

Exit codes: 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -H) HOST="$2"; shift 2 ;;
        -p) PORT="$2"; shift 2 ;;
        --ldaps) USE_LDAPS=1; shift ;;
        -Z) USE_STARTTLS=1; shift ;;
        -D) BINDDN="$2"; shift 2 ;;
        -W) BINDPW="$2"; shift 2 ;;
        -y) BINDPW_FILE="$2"; shift 2 ;;
        --ldapsearch-bin) LDAPSEARCH_OVERRIDE="$2"; shift 2 ;;
        --ldap-flavor) LDAP_FLAVOR="$2"; shift 2 ;;
        --key-file) KEY_FILE="$2"; shift 2 ;;
        --key-pw) KEY_PW="$2"; shift 2 ;;
        -b|--base) BASE="$2"; shift 2 ;;
        --repl-base) REPL_BASE="$2"; shift 2 ;;
        --agreement) AGREEMENTS+=("$2"); shift 2 ;;
        -w) PENDING_WARN="$2"; shift 2 ;;
        -c) PENDING_CRIT="$2"; shift 2 ;;
        --lag-warn) LAG_WARN="$2"; shift 2 ;;
        --lag-crit) LAG_CRIT="$2"; shift 2 ;;
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

# detect_flavor <binary-path> -> echoes "ibm" or "openldap"
# IBM's idsldapsearch (and the ldapsearch shipped under the SDS install) use a
# different flag syntax than OpenLDAP. Decide by binary name, then install path.
detect_flavor() {
    local b=$1 base
    base=$(basename "$b")
    if [[ "$base" == ids* ]]; then echo "ibm"; return; fi
    case "$b" in
        */ibm/ldap/*|*/IBM/ldap/*) echo "ibm" ;;
        *)                         echo "openldap" ;;
    esac
}

# Locate an LDAP search client and determine its flag flavor.
# Honors --ldapsearch-bin; otherwise searches PATH then the SDS install dirs.
LDAPSEARCH_BIN=""
find_ldapsearch() {
    if [[ -n "$LDAPSEARCH_OVERRIDE" ]]; then
        if [[ -x "$LDAPSEARCH_OVERRIDE" ]]; then
            LDAPSEARCH_BIN="$LDAPSEARCH_OVERRIDE"
        elif command -v "$LDAPSEARCH_OVERRIDE" >/dev/null 2>&1; then
            LDAPSEARCH_BIN=$(command -v "$LDAPSEARCH_OVERRIDE")
        else
            return 1
        fi
    else
        local c d
        for c in idsldapsearch ldapsearch; do
            if command -v "$c" >/dev/null 2>&1; then
                LDAPSEARCH_BIN=$(command -v "$c"); break
            fi
        done
        if [[ -z "$LDAPSEARCH_BIN" ]]; then
            # SDS tools are usually off-PATH under the install directory.
            for d in /opt/IBM/ldap/*/bin /opt/ibm/ldap/*/bin; do
                if [[ -x "$d/idsldapsearch" ]]; then LDAPSEARCH_BIN="$d/idsldapsearch"; break; fi
            done
        fi
    fi
    [[ -z "$LDAPSEARCH_BIN" ]] && return 1
    [[ -z "$LDAP_FLAVOR" ]] && LDAP_FLAVOR=$(detect_flavor "$LDAPSEARCH_BIN")
    return 0
}

# run_ldapsearch <base> <scope> <filter> [attr...]
# Sets global LDAP_OUT to the LDIF and returns the search exit code.
# Must NOT be called via command substitution, or LDAP_OUT would be set in a
# subshell and the return code would be that of the substitution, not the search.
LDAP_OUT=""
run_ldapsearch() {
    local base=$1 scope=$2 filter=$3; shift 3
    local rc=0
    local -a args=() envp=()

    if [[ "$LDAP_FLAVOR" == "ibm" ]]; then
        # IBM idsldapsearch: -h/-p, -L (single), simple bind by default, -w only.
        args=(-h "$HOST" -p "$PORT" -b "$base" -s "$scope" -L)
        if (( USE_LDAPS )); then
            args+=(-Z)
            [[ -n "$KEY_FILE" ]] && args+=(-K "$KEY_FILE")
            [[ -n "$KEY_PW" ]]   && args+=(-P "$KEY_PW")
        fi
        [[ -n "$BINDDN" ]] && args+=(-D "$BINDDN")
        # IBM has no password-file flag; read it and pass -w (visible in ps).
        local pw=""
        if [[ -n "$BINDPW_FILE" ]]; then
            pw=$(head -n1 "$BINDPW_FILE" 2>/dev/null) || true
        elif [[ -n "$BINDPW" ]]; then
            pw="$BINDPW"
        fi
        [[ -n "$pw" ]] && args+=(-w "$pw")
        # Ensure the SDS shared libraries resolve for an off-PATH binary.
        local root
        root=$(dirname "$(dirname "$LDAPSEARCH_BIN")")
        if [[ -d "$root/lib64" || -d "$root/lib" ]]; then
            envp=(env "LD_LIBRARY_PATH=$root/lib64:$root/lib:${LD_LIBRARY_PATH:-}")
        fi
    else
        # OpenLDAP ldapsearch: -H URI, -x simple auth, -LLL, -y password file.
        local uri proto="ldap"
        (( USE_LDAPS )) && proto="ldaps"
        uri="${proto}://${HOST}:${PORT}"
        args=(-x -H "$uri" -b "$base" -s "$scope" -LLL)
        (( USE_STARTTLS )) && args+=(-ZZ)
        [[ -n "$BINDDN" ]] && args+=(-D "$BINDDN")
        if [[ -n "$BINDPW_FILE" ]]; then
            args+=(-y "$BINDPW_FILE")
        elif [[ -n "$BINDPW" ]]; then
            args+=(-w "$BINDPW")
        fi
    fi
    args+=("$filter" "$@")

    LDAP_OUT=$(timeout --kill-after=2 "$TIMEOUT" \
        ${envp[@]+"${envp[@]}"} "$LDAPSEARCH_BIN" "${args[@]}" 2>&1) || rc=$?
    return "$rc"
}

# ldif_get <ldif> <attr> -> first value of attr (case-insensitive), empty if absent
ldif_get() {
    local ldif=$1 attr=$2
    printf '%s\n' "$ldif" | awk -v a="$attr" '
        BEGIN { IGNORECASE=1 }
        {
            idx = index($0, ":")
            if (idx == 0) next
            name = substr($0, 1, idx-1)
            val  = substr($0, idx+1)
            gsub(/^[ \t]+/, "", val)
            if (tolower(name) == tolower(a)) { print val; exit }
        }'
}

# is_number <string>
is_number() { [[ "$1" =~ ^[0-9]+$ ]]; }

# sanitize_label <string> -> perfdata-safe label (alnum and _ only)
sanitize_label() {
    local s=$1
    s=$(printf '%s' "$s" | tr -c 'A-Za-z0-9_' '_')
    # Collapse repeated underscores and trim leading/trailing ones.
    s=$(printf '%s' "$s" | sed -E 's/_+/_/g; s/^_//; s/_$//')
    printf '%s' "$s"
}

# state_is_error <state_value> -> 0 (true) if the state indicates a problem
state_is_error() {
    local lc; lc=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    local s
    for s in "${ERROR_STATES[@]}"; do
        if [[ "$lc" == *"$s"* ]]; then
            return 0
        fi
    done
    return 1
}

# gen_time_age <generalized-time> -> age in seconds on stdout, empty if unparsable
# Accepts YYYYMMDDHHMMSS[.f]Z (the SDS generalized-time form).
gen_time_age() {
    local t=$1 base epoch now
    base="${t%%.*}"          # strip fractional seconds
    base="${base%Z}"         # strip trailing Z
    [[ "$base" =~ ^[0-9]{14}$ ]] || return 1
    local y=${base:0:4} mo=${base:4:2} d=${base:6:2}
    local h=${base:8:2} mi=${base:10:2} s=${base:12:2}
    # GNU date and BSD date differ; try GNU form first, then BSD.
    if epoch=$(date -u -d "${y}-${mo}-${d}T${h}:${mi}:${s}Z" +%s 2>/dev/null); then
        :
    elif epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "${y}-${mo}-${d}T${h}:${mi}:${s}Z" +%s 2>/dev/null); then
        :
    else
        return 1
    fi
    now=$(date -u +%s)
    printf '%s' "$(( now - epoch ))"
}

# wanted_agreement <cn> -> 0 (true) if the agreement should be checked
wanted_agreement() {
    local cn=$1 a
    (( ${#AGREEMENTS[@]} == 0 )) && return 0
    for a in "${AGREEMENTS[@]}"; do
        [[ "$cn" == "$a" ]] && return 0
    done
    return 1
}

# Validate required search base early.
if [[ -z "$BASE" ]]; then
    record "${STATE_UNKNOWN}" "base" "No search base set; pass -b/--base with the suffix or replication context (e.g. -b 'dc=example,dc=com')"
fi

AGREEMENT_DNS=()
fetch_agreement_dns() {
    if ! find_ldapsearch; then
        record "${STATE_UNKNOWN}" "replication" \
            "No idsldapsearch/ldapsearch found on PATH or under /opt/*/ldap/*/bin - install openldap-clients or pass --ldapsearch-bin /path"
        return 1
    fi
    if [[ "$LDAP_FLAVOR" == "ibm" ]] && (( USE_STARTTLS )); then
        record "${STATE_UNKNOWN}" "replication" \
            "StartTLS (-Z) is not supported with the IBM client; use --ldaps (SSL) with --key-file"
        return 1
    fi

    local search_base="$BASE"
    [[ -n "$REPL_BASE" ]] && search_base="$REPL_BASE"

    local rc=0
    run_ldapsearch "$search_base" sub "(objectclass=${OC_AGREEMENT})" dn cn || rc=$?
    local ldif="$LDAP_OUT"

    if [[ ${rc} -eq 124 || ${rc} -eq 137 ]]; then
        record "${STATE_CRITICAL}" "replication" "agreement search timed out after ${TIMEOUT}s - server likely hung"
        return 1
    fi
    if [[ ${rc} -ne 0 ]]; then
        record "${STATE_CRITICAL}" "replication" "agreement search failed (rc=${rc}): $(printf '%s' "$ldif" | tail -n1)"
        return 1
    fi

    # Collect DNs of matching entries.
    local line dn=""
    while IFS= read -r line; do
        case "$line" in
            dn:\ *) dn="${line#dn: }"; AGREEMENT_DNS+=("$dn") ;;
            "dn::"*) dn="${line#dn:: }"; AGREEMENT_DNS+=("$dn") ;;
        esac
    done < <(printf '%s\n' "$ldif")

    return 0
}

check_agreement() {
    local dn=$1 cn state pending last_result last_addl last_id last_time
    local rc=0
    run_ldapsearch "$dn" base "(objectclass=*)" \
        cn "$ATTR_STATE" "$ATTR_PENDING" "$ATTR_LAST_RESULT" \
        "$ATTR_LAST_RESULT_ADDL" "$ATTR_LAST_CHANGE_ID" "$ATTR_LAST_RESULT_TIME" || rc=$?
    local ldif="$LDAP_OUT"

    if [[ ${rc} -eq 124 || ${rc} -eq 137 ]]; then
        record "${STATE_CRITICAL}" "replication" "read of agreement '${dn}' timed out after ${TIMEOUT}s"
        return
    fi
    if [[ ${rc} -ne 0 ]]; then
        record "${STATE_CRITICAL}" "replication" "read of agreement '${dn}' failed (rc=${rc}): $(printf '%s' "$ldif" | tail -n1)"
        return
    fi

    cn=$(ldif_get "$ldif" cn)
    [[ -z "$cn" ]] && cn="$dn"

    if ! wanted_agreement "$cn"; then
        return
    fi

    state=$(ldif_get "$ldif" "$ATTR_STATE")
    pending=$(ldif_get "$ldif" "$ATTR_PENDING")
    last_result=$(ldif_get "$ldif" "$ATTR_LAST_RESULT")
    last_addl=$(ldif_get "$ldif" "$ATTR_LAST_RESULT_ADDL")
    last_id=$(ldif_get "$ldif" "$ATTR_LAST_CHANGE_ID")
    last_time=$(ldif_get "$ldif" "$ATTR_LAST_RESULT_TIME")

    local label; label=$(sanitize_label "$cn")
    local worst=${STATE_OK}
    local reasons=()

    # --- State check ---
    if [[ -n "$state" ]] && state_is_error "$state"; then
        worst=${STATE_CRITICAL}
        reasons+=("state '${state}'")
    fi

    # --- Last result code check ---
    if is_number "$last_result" && (( last_result != 0 )); then
        worst=${STATE_CRITICAL}
        local rmsg="last result ${last_result}"
        [[ -n "$last_addl" ]] && rmsg+=" (${last_addl})"
        reasons+=("$rmsg")
    fi

    # --- Pending-change backlog check + perfdata ---
    if is_number "$pending"; then
        PERFDATA+=("pending_changes_${label}=${pending};${PENDING_WARN};${PENDING_CRIT};0;")
        if is_number "$PENDING_CRIT" && (( pending >= PENDING_CRIT )); then
            worst=${STATE_CRITICAL}
            reasons+=("${pending} pending changes >= crit ${PENDING_CRIT}")
        elif is_number "$PENDING_WARN" && (( pending >= PENDING_WARN )); then
            (( worst < STATE_WARNING )) && worst=${STATE_WARNING}
            reasons+=("${pending} pending changes >= warn ${PENDING_WARN}")
        fi
    else
        PERFDATA+=("pending_changes_${label}=U")
    fi

    # --- Optional lag check + perfdata ---
    if [[ -n "$last_time" ]]; then
        local age
        if age=$(gen_time_age "$last_time") && is_number "$age"; then
            PERFDATA+=("replication_lag_seconds_${label}=${age};${LAG_WARN};${LAG_CRIT};0;")
            if is_number "$LAG_CRIT" && (( age >= LAG_CRIT )); then
                worst=${STATE_CRITICAL}
                reasons+=("lag ${age}s >= crit ${LAG_CRIT}s")
            elif is_number "$LAG_WARN" && (( age >= LAG_WARN )); then
                (( worst < STATE_WARNING )) && worst=${STATE_WARNING}
                reasons+=("lag ${age}s >= warn ${LAG_WARN}s")
            fi
        fi
    fi

    # --- Tally + record ---
    local detail="agreement '${cn}'"
    [[ -n "$state" ]] && detail+=" state=${state}"
    is_number "$pending" && detail+=" pending=${pending}"
    is_number "$last_result" && detail+=" lastResult=${last_result}"
    [[ -n "$last_id" ]] && detail+=" lastChangeId=${last_id}"

    if (( worst == STATE_OK )); then
        AGREEMENTS_OK=$(( AGREEMENTS_OK + 1 ))
        record "${STATE_OK}" "$label" "$detail - healthy"
    else
        AGREEMENTS_ERROR=$(( AGREEMENTS_ERROR + 1 ))
        local why; why=$(IFS='; '; printf '%s' "${reasons[*]}")
        record "$worst" "$label" "$detail - ${why}"
    fi
}

if [[ -n "$BASE" ]] && fetch_agreement_dns; then
    if (( ${#AGREEMENT_DNS[@]} == 0 )); then
        SEARCHED_BASE="$BASE"
        [[ -n "$REPL_BASE" ]] && SEARCHED_BASE="$REPL_BASE"
        record "${STATE_UNKNOWN}" "replication" "no replication agreements found under ${SEARCHED_BASE}"
    else
        for adn in "${AGREEMENT_DNS[@]}"; do
            check_agreement "$adn"
        done
        # If --agreement filters were given but matched nothing, flag it.
        if (( ${#SUMMARY[@]} == 0 )); then
            record "${STATE_UNKNOWN}" "replication" "no agreements matched the requested --agreement filter(s)"
        fi
        PERFDATA=("agreements_ok=${AGREEMENTS_OK}" "agreements_error=${AGREEMENTS_ERROR}" "${PERFDATA[@]}")
    fi
fi

case $STATUS in
    "${STATE_OK}")       LABEL="OK"       ;;
    "${STATE_WARNING}")  LABEL="WARNING"  ;;
    "${STATE_CRITICAL}") LABEL="CRITICAL" ;;
    *)                   LABEL="UNKNOWN"  ;;
esac

if [[ ${#PERFDATA[@]} -gt 0 ]]; then
    echo "${PLUGIN_NAME} ${LABEL} - ${SUMMARY[*]} | ${PERFDATA[*]}"
else
    echo "${PLUGIN_NAME} ${LABEL} - ${SUMMARY[*]}"
fi
for d in "${DETAILS[@]}"; do echo "$d"; done

exit "${STATUS}"
