#!/usr/bin/env bash
# MIT License
# Copyright (c) 2025 ISW Kudos
# https://github.com/isw-kudos/icinga-plugins/blob/main/LICENSE
#
# check_isds_monitor - Icinga/Nagios plugin for IBM Security Directory Server
#
# Reads the cn=monitor backend of an IBM Security Directory Server (SDS, formerly
# IBM Tivoli Directory Server, now IBM Security Verify Directory) over LDAP and
# alerts on operational health that a simple bind/search check cannot see:
#
#   1. workers     - worker thread pool exhaustion (available vs total).
#                    Available workers hitting zero is the classic "port open
#                    but server hung" signature.
#   2. connections - current connections vs an optional configured maximum.
#   3. throughput  - ops/search/bind counters emitted as perfdata counters (c)
#                    for rate graphing. No thresholds (informational).
#   4. cache       - entry/filter/group cache hit ratios (informational; opt in
#                    to alerting with --cache-warn/--cache-crit).
#
# Designed to run locally on the SDS host using the bundled idsldapsearch, but
# falls back to a standard ldapsearch and works remotely too.
#
# NOTE: cn=monitor attribute names vary slightly across SDS/ISVD versions. The
# expected names are defined in the "Attribute names" block below - adjust them
# there if a sub-check reports an attribute as not found.
#
# Exit codes: 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN
#

set -euo pipefail

PLUGIN_NAME="check_isds_monitor"
PLUGIN_VERSION="1.1.2"

# ---------- Defaults ----------
HOST="127.0.0.1"
PORT=389
USE_LDAPS=0
USE_STARTTLS=0
BINDDN=""
BINDPW=""
BINDPW_FILE=""
MONITOR_BASE="cn=monitor"

# LDAP client selection. The plugin auto-detects whether the client uses IBM
# (idsldapsearch: -h/-p/-L/-w) or OpenLDAP (ldapsearch: -H/-x/-LLL/-y) flag
# syntax and builds the right arguments. Override either with the flags below.
LDAPSEARCH_OVERRIDE=""   # --ldapsearch-bin: absolute path to the client binary
LDAP_FLAVOR=""           # --ldap-flavor: force "ibm" or "openldap" (else auto)
KEY_FILE=""              # --key-file: IBM SSL key database (.kdb) for --ldaps
KEY_PW=""                # --key-pw: IBM SSL key database password/stash

# Worker pool thresholds (alert when AVAILABLE workers drop low)
WORKERS_WARN=2
WORKERS_CRIT=1
# Connection thresholds (alert when CURRENT connections climb high); empty = off
CONN_WARN=""
CONN_CRIT=""
# Cache hit-ratio thresholds in percent (alert when ratio drops low); empty = off.
# Off by default: filter caches legitimately run a low hit ratio on healthy
# servers, so cache ratios are informational (perfdata) unless you opt in.
CACHE_WARN=""
CACHE_CRIT=""

TIMEOUT=30

CHECK_WORKERS=1
CHECK_CONNECTIONS=1
CHECK_THROUGHPUT=1
CHECK_CACHE=1

# ---------- Attribute names (adjust per SDS version if needed) ----------
ATTR_AVAILABLE_WORKERS="available_workers"
ATTR_TOTAL_WORKERS="total_workers"
ATTR_CURRENT_CONNECTIONS="currentconnections"
ATTR_TOTAL_CONNECTIONS="totalconnections"
# Throughput counters: label:attribute pairs
THROUGHPUT_ATTRS=(
    "ops_completed:opscompleted"
    "ops_initiated:opsinitiated"
    "searches_completed:searchescompleted"
    "binds_completed:bindscompleted"
    "entries_sent:entriessent"
)
# Cache hit-ratio sources: label:hit_attr:miss_attr (ratio = hit/(hit+miss)).
# SDS/ISVD expose hit + miss counters; the hit ratio is derived. ACL cache is
# omitted because the server only reports acl_cache=TRUE/acl_cache_size (no
# hit/miss). Adjust these names if your SDS version differs.
CACHE_ATTRS=(
    "entry_cache:entry_cache_hit:entry_cache_miss"
    "filter_cache:filter_cache_hit:filter_cache_miss"
    "group_cache:group_members_cache_hit:group_members_cache_miss"
)

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

Connection:
  -H HOST                LDAP host/IP (default: ${HOST})
  -p PORT                LDAP port (default: ${PORT})
  --ldaps                Use ldaps:// (implies the LDAPS port; set -p too)
  -Z                     Use StartTLS on the plain port
  -D BINDDN              Bind DN (e.g. cn=monitor or a read-only monitor account)
  -W PASSWORD            Bind password (discouraged - visible in process list)
  -y PASSWORD_FILE       Read bind password from first line of file (preferred)
  --monitor-base DN      Monitor search base (default: ${MONITOR_BASE})

LDAP client:
  --ldapsearch-bin PATH  Absolute path to idsldapsearch/ldapsearch (else searched
                         on PATH and under /opt/*/ldap/*/bin)
  --ldap-flavor FLAVOR   Force "ibm" or "openldap" flag syntax (else auto-detected)
  --key-file PATH        IBM SSL key database (.kdb) - used with --ldaps (IBM)
  --key-pw PASS          IBM SSL key database password/stash - used with --ldaps

Thresholds:
  --workers-warn N       Warn when available workers <= N (default: ${WORKERS_WARN})
  --workers-crit N       Crit when available workers <= N (default: ${WORKERS_CRIT})
  --conn-warn N          Warn when current connections >= N (default: off)
  --conn-crit N          Crit when current connections >= N (default: off)
  --cache-warn PCT       Warn when a cache hit ratio < PCT% (default: off)
  --cache-crit PCT       Crit when a cache hit ratio < PCT% (default: off)

Sub-check toggles:
  --no-workers           Disable worker pool check
  --no-connections       Disable connection count check
  --no-throughput        Disable throughput counters
  --no-cache             Disable cache hit-ratio check

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
        --monitor-base) MONITOR_BASE="$2"; shift 2 ;;
        --workers-warn) WORKERS_WARN="$2"; shift 2 ;;
        --workers-crit) WORKERS_CRIT="$2"; shift 2 ;;
        --conn-warn) CONN_WARN="$2"; shift 2 ;;
        --conn-crit) CONN_CRIT="$2"; shift 2 ;;
        --cache-warn) CACHE_WARN="$2"; shift 2 ;;
        --cache-crit) CACHE_CRIT="$2"; shift 2 ;;
        --no-workers) CHECK_WORKERS=0; shift ;;
        --no-connections) CHECK_CONNECTIONS=0; shift ;;
        --no-throughput) CHECK_THROUGHPUT=0; shift ;;
        --no-cache) CHECK_CACHE=0; shift ;;
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
    LDAP_OUT=$(unfold_ldif "$LDAP_OUT")
    return "$rc"
}

# unfold_ldif <ldif> -> undo RFC 2849 line folding (continuation lines start with
# a single space). IBM idsldapsearch -L wraps long lines, which would otherwise
# parse as truncated values.
unfold_ldif() {
    printf '%s\n' "$1" | awk '
        NR==1 { acc=$0; next }
        /^ /  { acc=acc substr($0,2); next }
        { print acc; acc=$0 }
        END   { if (NR>0) print acc }'
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

MONITOR_LDIF=""
fetch_monitor() {
    if ! find_ldapsearch; then
        record "${STATE_UNKNOWN}" "monitor" \
            "No idsldapsearch/ldapsearch found on PATH or under /opt/*/ldap/*/bin - install openldap-clients or pass --ldapsearch-bin /path"
        return 1
    fi
    if [[ "$LDAP_FLAVOR" == "ibm" ]] && (( USE_STARTTLS )); then
        record "${STATE_UNKNOWN}" "monitor" \
            "StartTLS (-Z) is not supported with the IBM client; use --ldaps (SSL) with --key-file"
        return 1
    fi
    local rc=0
    run_ldapsearch "$MONITOR_BASE" base "(objectclass=*)" || rc=$?
    MONITOR_LDIF="$LDAP_OUT"
    if [[ ${rc} -eq 124 || ${rc} -eq 137 ]]; then
        record "${STATE_CRITICAL}" "monitor" "cn=monitor search timed out after ${TIMEOUT}s - server likely hung"
        return 1
    fi
    if [[ ${rc} -ne 0 ]]; then
        record "${STATE_CRITICAL}" "monitor" "cn=monitor search failed (rc=${rc}): $(printf '%s' "$MONITOR_LDIF" | tail -n1)"
        return 1
    fi
    return 0
}

check_workers() {
    local avail total
    avail=$(ldif_get "$MONITOR_LDIF" "$ATTR_AVAILABLE_WORKERS")
    total=$(ldif_get "$MONITOR_LDIF" "$ATTR_TOTAL_WORKERS")

    if ! is_number "$avail"; then
        record "${STATE_UNKNOWN}" "workers" "Attribute '${ATTR_AVAILABLE_WORKERS}' not found in cn=monitor"
        PERFDATA+=("available_workers=U")
        return
    fi

    local maxp=""
    is_number "$total" && maxp="$total"
    PERFDATA+=("available_workers=${avail};${WORKERS_WARN}:;${WORKERS_CRIT}:;0;${maxp}")
    is_number "$total" && PERFDATA+=("total_workers=${total}")

    local detail="available workers ${avail}"
    is_number "$total" && detail+="/${total}"

    if (( avail <= WORKERS_CRIT )); then
        record "${STATE_CRITICAL}" "workers" "${detail} - pool near/at exhaustion"
    elif (( avail <= WORKERS_WARN )); then
        record "${STATE_WARNING}" "workers" "${detail} - pool running low"
    else
        record "${STATE_OK}" "workers" "$detail"
    fi
}

check_connections() {
    local cur tot
    cur=$(ldif_get "$MONITOR_LDIF" "$ATTR_CURRENT_CONNECTIONS")
    tot=$(ldif_get "$MONITOR_LDIF" "$ATTR_TOTAL_CONNECTIONS")

    if ! is_number "$cur"; then
        record "${STATE_UNKNOWN}" "connections" "Attribute '${ATTR_CURRENT_CONNECTIONS}' not found in cn=monitor"
        PERFDATA+=("current_connections=U")
        return
    fi

    PERFDATA+=("current_connections=${cur};${CONN_WARN};${CONN_CRIT};0;")
    is_number "$tot" && PERFDATA+=("total_connections=${tot}c")

    if is_number "$CONN_CRIT" && (( cur >= CONN_CRIT )); then
        record "${STATE_CRITICAL}" "connections" "${cur} current connections >= crit ${CONN_CRIT}"
    elif is_number "$CONN_WARN" && (( cur >= CONN_WARN )); then
        record "${STATE_WARNING}" "connections" "${cur} current connections >= warn ${CONN_WARN}"
    else
        record "${STATE_OK}" "connections" "${cur} current connections"
    fi
}

check_throughput() {
    local found=0 pair label attr val
    for pair in "${THROUGHPUT_ATTRS[@]}"; do
        label="${pair%%:*}"
        attr="${pair##*:}"
        val=$(ldif_get "$MONITOR_LDIF" "$attr")
        if is_number "$val"; then
            PERFDATA+=("${label}=${val}c")
            found=1
        fi
    done
    if (( found )); then
        record "${STATE_OK}" "throughput" "operation counters collected"
    else
        record "${STATE_UNKNOWN}" "throughput" "no throughput counters found in cn=monitor"
    fi
}

check_cache() {
    local worst=${STATE_OK} any=0 triple label hit_attr miss_attr hit miss total ratio low=()
    for triple in "${CACHE_ATTRS[@]}"; do
        label="${triple%%:*}"
        local rest="${triple#*:}"
        hit_attr="${rest%%:*}"
        miss_attr="${rest##*:}"
        hit=$(ldif_get "$MONITOR_LDIF" "$hit_attr")
        miss=$(ldif_get "$MONITOR_LDIF" "$miss_attr")
        if ! is_number "$hit" || ! is_number "$miss"; then
            continue
        fi
        total=$(( hit + miss ))
        (( total == 0 )) && continue
        any=1
        ratio=$(( hit * 100 / total ))
        local pw="" pc=""
        is_number "$CACHE_WARN" && pw="${CACHE_WARN}:"
        is_number "$CACHE_CRIT" && pc="${CACHE_CRIT}:"
        PERFDATA+=("${label}_hit_ratio=${ratio}%;${pw};${pc};0;100")
        if is_number "$CACHE_CRIT" && (( ratio < CACHE_CRIT )); then
            low+=("${label} ${ratio}%"); worst=${STATE_CRITICAL}
        elif is_number "$CACHE_WARN" && (( ratio < CACHE_WARN )); then
            low+=("${label} ${ratio}%"); (( worst < STATE_WARNING )) && worst=${STATE_WARNING}
        fi
    done

    if (( ! any )); then
        record "${STATE_UNKNOWN}" "cache" "no cache hit/miss counters found in cn=monitor"
        return
    fi
    if (( worst == STATE_OK )); then
        record "${STATE_OK}" "cache" "cache hit ratios collected"
    else
        record "$worst" "cache" "low cache hit ratio: ${low[*]}"
    fi
}

if fetch_monitor; then
    (( CHECK_WORKERS ))     && check_workers
    (( CHECK_CONNECTIONS )) && check_connections
    (( CHECK_THROUGHPUT ))  && check_throughput
    (( CHECK_CACHE ))       && check_cache
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
