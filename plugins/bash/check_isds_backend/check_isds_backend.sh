#!/usr/bin/env bash
# MIT License
# Copyright (c) 2025 ISW Kudos
# https://github.com/isw-kudos/icinga-plugins/blob/main/LICENSE
#
# check_isds_backend - Icinga/Nagios plugin for IBM Security Directory Server
#
# Monitors the HOST-LOCAL backend health of an IBM Security Directory Server
# (SDS, formerly IBM Tivoli Directory Server, now IBM Security Verify Directory).
# Designed to run LOCALLY on the SDS host (via the Icinga agent), complementing
# check_isds_monitor (which reads cn=monitor over LDAP) by checking the things
# only visible on the box itself: process liveness and the DB2 storage backend.
#
# Sub-checks (all enabled by default, individually toggleable):
#   1. proc            - SDS/DB2 processes are running (pgrep -f):
#                          ibmslapd  -> CRITICAL if down (the LDAP server)
#                          ibmdiradm -> WARNING (or CRITICAL with --diradm-crit)
#                          db2sysc   -> CRITICAL if down (DB2 backend engine)
#   2. db2-tablespace  - DB2 tablespace utilization %. WARN/CRIT if any tablespace
#                        exceeds the threshold. Needs --db2-instance/--db2-database.
#   3. db2-logs        - DB2 transaction-log utilization %. WARN/CRIT on high use.
#
# DB2 commands must run as the instance owner. If --db2-user is given, db2 calls
# are wrapped as `su - <user> -c '...'` (the Icinga user then needs sudo rights;
# see INSTALL.md). Every DB2 sub-check DEGRADES GRACEFULLY: a missing db2 binary,
# missing instance/db args, or an su failure yields UNKNOWN for that sub-check,
# never a hard crash.
#
# NOTE: process names and DB2 SQL/db2pd parsing vary across SDS/DB2 versions.
# The pgrep patterns are in the "Process patterns" block and the DB2 queries are
# in clearly marked "DB2 QUERY" blocks below - adjust them there if needed.
#
# Exit codes: 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN
#

set -euo pipefail

PLUGIN_NAME="check_isds_backend"
PLUGIN_VERSION="1.0.0"

# ---------- Defaults ----------
# Tablespace utilization thresholds (percent)
TBSP_WARN=85
TBSP_CRIT=95
# Transaction-log utilization thresholds (percent)
LOG_WARN=80
LOG_CRIT=90

# DB2 connection details (required for the db2-* sub-checks)
DB2_INSTANCE=""
DB2_DATABASE=""
DB2_USER=""

# ibmdiradm severity when not running: WARNING by default, CRITICAL with --diradm-crit
DIRADM_CRIT=0
CHECK_DIRADM=1

TIMEOUT=30

# ---------- Process patterns (adjust per SDS version if needed) ----------
# Matched with `pgrep -f`. Confirm against the real process names on the host.
PROC_IBMSLAPD="ibmslapd"
PROC_IBMDIRADM="ibmdiradm"
PROC_DB2="db2sysc"

# Sub-check enable flags. Default: all on. A --check <name> flips to allowlist
# mode (only explicitly selected sub-checks run); --no-<name> always disables.
CHECK_PROC=1
CHECK_TBSP=1
CHECK_LOGS=1
ALLOWLIST=0

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

DB2 connection (required for the db2-* sub-checks):
  --db2-instance NAME    DB2 instance name (e.g. dsrdbm01)
  --db2-database DB      DB2 database name (e.g. ldapdb2)
  --db2-user USER        Run db2 as this OS user via 'su - USER -c ...'
                         (the Icinga user needs sudo rights - see INSTALL.md)

Thresholds:
  -w PCT                 Tablespace warn threshold (default: ${TBSP_WARN})
  -c PCT                 Tablespace crit threshold (default: ${TBSP_CRIT})
  --log-warn PCT         Transaction-log warn threshold (default: ${LOG_WARN})
  --log-crit PCT         Transaction-log crit threshold (default: ${LOG_CRIT})

Process check:
  --diradm-crit          Treat a missing ibmdiradm as CRITICAL (default: WARNING)
  --no-diradm            Skip the ibmdiradm process check entirely

Sub-check selection:
  --check NAME           Run only this sub-check (repeatable). NAME is one of:
                         proc, db2-tablespace, db2-logs. If never given, all run.
  --no-proc              Disable the process liveness sub-check
  --no-db2-tablespace    Disable the DB2 tablespace sub-check
  --no-db2-logs          Disable the DB2 transaction-log sub-check

General:
  -t SECONDS             Timeout per external command (default: ${TIMEOUT})
  -V, --version          Show version
  -h, --help             Show this help

Exit codes: 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN
EOF
}

# --check switches to allowlist mode: first --check disables all, then each
# named sub-check is re-enabled.
select_check() {
    if (( ! ALLOWLIST )); then
        ALLOWLIST=1
        CHECK_PROC=0
        CHECK_TBSP=0
        CHECK_LOGS=0
    fi
    case "$1" in
        proc)            CHECK_PROC=1 ;;
        db2-tablespace)  CHECK_TBSP=1 ;;
        db2-logs)        CHECK_LOGS=1 ;;
        *) echo "${PLUGIN_NAME} UNKNOWN - Unknown --check value: $1 (use proc|db2-tablespace|db2-logs)"
           exit "${STATE_UNKNOWN}" ;;
    esac
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --db2-instance) DB2_INSTANCE="$2"; shift 2 ;;
        --db2-database) DB2_DATABASE="$2"; shift 2 ;;
        --db2-user) DB2_USER="$2"; shift 2 ;;
        -w) TBSP_WARN="$2"; shift 2 ;;
        -c) TBSP_CRIT="$2"; shift 2 ;;
        --log-warn) LOG_WARN="$2"; shift 2 ;;
        --log-crit) LOG_CRIT="$2"; shift 2 ;;
        --diradm-crit) DIRADM_CRIT=1; shift ;;
        --no-diradm) CHECK_DIRADM=0; shift ;;
        --check) select_check "$2"; shift 2 ;;
        --no-proc) CHECK_PROC=0; shift ;;
        --no-db2-tablespace) CHECK_TBSP=0; shift ;;
        --no-db2-logs) CHECK_LOGS=0; shift ;;
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

# is_number <string>
is_number() { [[ "$1" =~ ^[0-9]+$ ]]; }

# count_procs <pattern> -> number of matching processes (0 if none).
# pgrep exits 1 when nothing matches; that must not trip `set -e`/pipefail.
count_procs() {
    local n
    n=$(pgrep -f "$1" 2>/dev/null | wc -l | tr -d ' ') || n=0
    is_number "$n" || n=0
    printf '%s' "$n"
}

# sanitize <string> -> perfdata-safe label fragment (alnum/underscore, lowercased)
sanitize() {
    local s="$1"
    s="${s//[^A-Za-z0-9]/_}"
    printf '%s' "${s,,}"
}

# ---------------------------------------------------------------------------
# DB2 command runner.
#
# run_db2 <db2-command-string>
#   Sets global DB2_OUT to combined stdout+stderr and DB2_RC to the exit code.
#   Must NOT be called via command substitution, or DB2_OUT/DB2_RC would be set
#   in a subshell and lost. When --db2-user is set, the command is run as that
#   user via `su - USER -c '...'` (sudo wraps this if the Icinga user is not
#   already root - see INSTALL.md). Otherwise it runs as the current user.
# ---------------------------------------------------------------------------
DB2_OUT=""
DB2_RC=0
run_db2() {
    local db2cmd=$1
    DB2_OUT=""
    DB2_RC=0
    if [[ -n "$DB2_USER" ]]; then
        DB2_OUT=$(timeout --kill-after=2 "$TIMEOUT" su - "$DB2_USER" -c "$db2cmd" 2>&1) || DB2_RC=$?
    else
        DB2_OUT=$(timeout --kill-after=2 "$TIMEOUT" bash -c "$db2cmd" 2>&1) || DB2_RC=$?
    fi
    return 0
}

# Guard: shared preflight for the DB2 sub-checks. Records UNKNOWN and returns 1
# if db2 is unusable so the sub-check can bail without crashing.
db2_preflight() {
    local short=$1
    # When running db2 as ourselves, db2 must be in PATH. When running via su,
    # the instance owner's profile provides db2, so we can't usefully test here.
    if [[ -z "$DB2_USER" ]] && ! command -v db2 >/dev/null 2>&1; then
        record "${STATE_UNKNOWN}" "$short" "db2 CLI not found in PATH (set --db2-user to run as the instance owner)"
        return 1
    fi
    if [[ -z "$DB2_INSTANCE" || -z "$DB2_DATABASE" ]]; then
        record "${STATE_UNKNOWN}" "$short" "--db2-instance and --db2-database are required for this sub-check"
        return 1
    fi
    return 0
}

# Interpret a timeout/su failure on DB2_RC. Returns 0 if it handled an error
# (and recorded it), 1 if the command appears to have run.
db2_rc_failed() {
    local short=$1
    if [[ ${DB2_RC} -eq 124 || ${DB2_RC} -eq 137 ]]; then
        record "${STATE_CRITICAL}" "$short" "DB2 query timed out after ${TIMEOUT}s - backend likely hung"
        return 0
    fi
    if [[ ${DB2_RC} -ne 0 ]]; then
        record "${STATE_UNKNOWN}" "$short" "DB2 query failed (rc=${DB2_RC}): $(printf '%s' "$DB2_OUT" | tail -n1)"
        return 0
    fi
    return 1
}

check_proc() {
    local count

    # ibmslapd - the LDAP server. CRITICAL if down.
    count=$(count_procs "$PROC_IBMSLAPD")
    PERFDATA+=("procs_ibmslapd=${count}")
    if (( count > 0 )); then
        record "${STATE_OK}" "proc_ibmslapd" "ibmslapd running (${count})"
    else
        record "${STATE_CRITICAL}" "proc_ibmslapd" "ibmslapd not running"
    fi

    # db2sysc - the DB2 backend engine. CRITICAL if down.
    count=$(count_procs "$PROC_DB2")
    PERFDATA+=("procs_db2=${count}")
    if (( count > 0 )); then
        record "${STATE_OK}" "proc_db2" "db2sysc running (${count})"
    else
        record "${STATE_CRITICAL}" "proc_db2" "db2sysc not running"
    fi

    # ibmdiradm - the admin daemon. WARNING by default, CRITICAL with --diradm-crit.
    if (( CHECK_DIRADM )); then
        count=$(count_procs "$PROC_IBMDIRADM")
        PERFDATA+=("procs_ibmdiradm=${count}")
        if (( count > 0 )); then
            record "${STATE_OK}" "proc_ibmdiradm" "ibmdiradm running (${count})"
        elif (( DIRADM_CRIT )); then
            record "${STATE_CRITICAL}" "proc_ibmdiradm" "ibmdiradm not running"
        else
            record "${STATE_WARNING}" "proc_ibmdiradm" "ibmdiradm not running"
        fi
    fi
}

check_tablespace() {
    db2_preflight "db2_tablespace" || return

    # --- DB2 QUERY (tablespace utilization) --------------------------------
    # May need adjustment per DB2 version. SYSIBMADM.TBSP_UTILIZATION exposes
    # TBSP_UTILIZATION_PERCENT for permanent/auto-resize tablespaces. -x strips
    # headers/footers so each line is "TBSP_NAME  PCT".
    local sql="SELECT TBSP_NAME, INT(TBSP_UTILIZATION_PERCENT) FROM SYSIBMADM.TBSP_UTILIZATION WHERE TBSP_UTILIZATION_PERCENT IS NOT NULL"
    local db2cmd="db2 connect to ${DB2_DATABASE} >/dev/null && db2 -x \"${sql}\""
    # -----------------------------------------------------------------------

    run_db2 "$db2cmd"
    db2_rc_failed "db2_tablespace" && return

    local worst=${STATE_OK} any=0 high=() name pct safe
    while read -r name pct; do
        [[ -z "$name" ]] && continue
        is_number "$pct" || continue
        any=1
        safe=$(sanitize "$name")
        PERFDATA+=("tablespace_used_pct_${safe}=${pct}%;${TBSP_WARN};${TBSP_CRIT};0;100")
        if (( pct >= TBSP_CRIT )); then
            high+=("${name} ${pct}%"); worst=${STATE_CRITICAL}
        elif (( pct >= TBSP_WARN )); then
            high+=("${name} ${pct}%"); (( worst < STATE_WARNING )) && worst=${STATE_WARNING}
        fi
    done < <(printf '%s\n' "$DB2_OUT")

    if (( ! any )); then
        record "${STATE_UNKNOWN}" "db2_tablespace" "no tablespace utilization rows parsed (check DB2 version/SQL)"
        return
    fi
    if (( worst == STATE_OK )); then
        record "${STATE_OK}" "db2_tablespace" "all tablespaces below ${TBSP_WARN}%"
    else
        record "$worst" "db2_tablespace" "high tablespace utilization: ${high[*]}"
    fi
}

check_logs() {
    db2_preflight "db2_logs" || return

    # --- DB2 QUERY (transaction-log utilization) ---------------------------
    # May need adjustment per DB2 version. MON_GET_TRANSACTION_LOG (DB2 9.7+)
    # gives used vs total log space. We compute used% = used/(used+available).
    # If MON_GET_TRANSACTION_LOG is unavailable on your version, replace this
    # with a `db2pd -db <db> -logs` parse instead.
    local sql="SELECT INT( (FLOAT(TOTAL_LOG_USED) / NULLIF(TOTAL_LOG_USED + TOTAL_LOG_AVAILABLE, 0)) * 100 ) FROM TABLE(MON_GET_TRANSACTION_LOG(-1))"
    local db2cmd="db2 connect to ${DB2_DATABASE} >/dev/null && db2 -x \"${sql}\""
    # -----------------------------------------------------------------------

    run_db2 "$db2cmd"
    db2_rc_failed "db2_logs" && return

    # First numeric token in the output is the used%.
    local pct=""
    pct=$(printf '%s\n' "$DB2_OUT" | tr -s ' ' '\n' | grep -E '^[0-9]+$' | head -n1 || true)

    if ! is_number "$pct"; then
        record "${STATE_UNKNOWN}" "db2_logs" "could not parse log utilization from DB2 output (check DB2 version/SQL)"
        PERFDATA+=("log_used_pct=U;${LOG_WARN};${LOG_CRIT};0;100")
        return
    fi

    PERFDATA+=("log_used_pct=${pct}%;${LOG_WARN};${LOG_CRIT};0;100")
    if (( pct >= LOG_CRIT )); then
        record "${STATE_CRITICAL}" "db2_logs" "transaction log ${pct}% used (>= crit ${LOG_CRIT}%)"
    elif (( pct >= LOG_WARN )); then
        record "${STATE_WARNING}" "db2_logs" "transaction log ${pct}% used (>= warn ${LOG_WARN}%)"
    else
        record "${STATE_OK}" "db2_logs" "transaction log ${pct}% used"
    fi
}

# A sub-check returning non-zero (e.g. an early `return` after recording UNKNOWN)
# must not terminate the plugin under `set -e`, so each dispatch is guarded.
(( CHECK_PROC )) && check_proc || true
(( CHECK_TBSP )) && check_tablespace || true
(( CHECK_LOGS )) && check_logs || true

if [[ ${#SUMMARY[@]} -eq 0 ]]; then
    echo "${PLUGIN_NAME} UNKNOWN - No sub-checks selected"
    exit "${STATE_UNKNOWN}"
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
