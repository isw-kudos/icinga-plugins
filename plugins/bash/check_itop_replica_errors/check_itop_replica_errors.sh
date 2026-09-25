#!/usr/bin/env bash
# MIT License
# Copyright (c) 2025 ISW Kudos
# https://github.com/isw-kudos/icinga-plugins/blob/main/LICENSE
#
# check_itop_replica_errors - iTop synchro replicas carrying an error, per
# data source, compared against a recorded baseline.
#
# Two things about this check are deliberate and easy to get wrong.
#
# 1. It counts `status_last_error <> ''`, NOT `status = 'error'`.
#    priv_sync_replica.status is an enum of
#    ('modified','new','obsolete','orphan','synchronized') - there is no
#    'error' member, so a check written against it returns zero rows forever
#    and is indistinguishable from a healthy result.
#
# 2. It alerts above a BASELINE, not above zero. Several sources carry a
#    stable, understood, pre-existing fault. Alerting on non-zero would alert
#    permanently, and a permanent alert is muted within a week.

set -euo pipefail

PLUGIN_NAME="check_itop_replica_errors"
PLUGIN_VERSION="1.0.0"

# --- Defaults ---
DB_HOST="127.0.0.1"
DB_PORT="3306"
DB_NAME="itop"
DB_USER=""
DEFAULTS_FILE=""
PASSWORD_FILE=""
MYSQL_BIN=""
BASELINE_SPEC=""
BASELINE_DEFAULT=0
IGNORE_SOURCES=""
WARN_THRESHOLD=1       # how far above baseline is worth a WARNING
CRIT_THRESHOLD=""      # empty disables the CRITICAL comparison entirely
TIMEOUT=30

# --- Exit Codes ---
STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3

# Internal severity, ordered so a real regression outranks an UNKNOWN.
SEV_OK=0
SEV_UNKNOWN=1
SEV_WARN=2
SEV_CRIT=3
SEVERITY=${SEV_OK}

DETAILS=()
PERFDATA=()

declare -A BASELINE=()
declare -A IGNORED=()

RUN_SQL_OUT=""
RUN_SQL_ERR=""
RUN_SQL_RC=0

TMP_OUT=""
TMP_ERR=""
trap 'rm -f -- "$TMP_OUT" "$TMP_ERR" 2>/dev/null || true' EXIT

usage() {
    cat <<EOF
Usage: ${PLUGIN_NAME} [-H <host>] [-P <port>] [-d <database>]
                      [--defaults-file <path> | --password-file <path>] [-u <user>]
                      [--baseline '<id>=<n>,...'] [--baseline-default <n>]
                      [--ignore-source <id,...>] [-w <n>] [-c <n>]
                      [-t <seconds>] [-V] [-h]

Counts iTop synchro replicas carrying an error, grouped by data source, and
compares each source against a recorded baseline.

Options:
  -H               Database host (default: ${DB_HOST})
  -P               Database port (default: ${DB_PORT})
  -d               Database name (default: ${DB_NAME})
  -u               Database user (omit if the defaults file supplies it)
      --defaults-file   my.cnf-style file holding the credentials. This is the
                        recommended way to pass a password: there is deliberately
                        no -p option, because a password on the command line is
                        visible in the process list.
      --password-file   Alternative: a file whose first line is the password.
      --mysql-bin       Client binary to use (default: mysql, then mariadb)
      --baseline        Known-good error count per source, e.g. '1=39,2=132'.
                        A source is only alerted on when it rises above its own
                        baseline.
      --baseline-default Baseline for a source not named in --baseline
                        (default: ${BASELINE_DEFAULT})
      --ignore-source   Comma-separated source ids to skip entirely - use for
                        sources that are dead by design and would alert forever
  -w               Warning threshold: how far above baseline counts (default: ${WARN_THRESHOLD})
  -c               Critical threshold above baseline (default: unset, never CRITICAL)
  -t, --timeout    Query timeout in seconds (default: ${TIMEOUT})
  -V, --version    Show version
  -h, --help       Show this help

Exit codes: 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN
EOF
    exit "${STATE_UNKNOWN}"
}

is_number() { [[ "$1" =~ ^[0-9]+$ ]]; }

escalate() { local lvl=$1; if (( lvl > SEVERITY )); then SEVERITY=$lvl; fi; }

exit_unknown() {
    echo "${PLUGIN_NAME} UNKNOWN - $1"
    exit "${STATE_UNKNOWN}"
}

check_dependencies() {
    if [[ -z "$MYSQL_BIN" ]]; then
        if command -v mysql >/dev/null 2>&1; then
            MYSQL_BIN="mysql"
        elif command -v mariadb >/dev/null 2>&1; then
            MYSQL_BIN="mariadb"
        else
            exit_unknown "Required command not found: mysql (or mariadb)"
        fi
    fi
    command -v "$MYSQL_BIN" >/dev/null 2>&1 || \
        exit_unknown "Required command not found: ${MYSQL_BIN}"
    command -v timeout >/dev/null 2>&1 || \
        exit_unknown "Required command not found: timeout"
}

# first_error_line FILE
# The client prefixes its stderr with deprecation notices - MariaDB 11 emits
# "WARNING: option --ssl-verify-server-cert is deprecated" on every connection.
# A plain `head -n1` would surface that instead of the real failure.
first_error_line() {
    local f=$1 line=""
    line=$(grep -m1 -E '^(ERROR|.*ERROR [0-9]+)' "$f" 2>/dev/null) || true
    if [[ -z "$line" ]]; then
        line=$(grep -m1 -v -E '^([Ww]arning|WARNING|\[Warning\]|.*: \[Warning\])' "$f" 2>/dev/null) || true
    fi
    if [[ -z "$line" ]]; then
        line=$(head -n1 "$f" 2>/dev/null) || true
    fi
    printf '%s' "$line"
}

# run_sql <sql> - see check_itop_cron for the full rationale.
#   RUN_SQL_RC 0 = answered, 124/137 = timed out, anything else = failure.
#   Empty RUN_SQL_OUT with rc 0 means zero rows, unambiguously.
run_sql() {
    local sql=$1 rc=0
    local args=()

    RUN_SQL_OUT=""; RUN_SQL_ERR=""; RUN_SQL_RC=0

    if [[ -n "$DEFAULTS_FILE" ]]; then
        args+=("--defaults-file=${DEFAULTS_FILE}")
    else
        args+=("--no-defaults")
    fi
    args+=(
        --batch
        --skip-column-names
        "--connect-timeout=${TIMEOUT}"
        "--host=${DB_HOST}"
        "--port=${DB_PORT}"
        "--database=${DB_NAME}"
    )
    [[ -n "$DB_USER" ]] && args+=("--user=${DB_USER}")

    TMP_OUT=$(mktemp) || { RUN_SQL_RC=250; return 0; }
    TMP_ERR=$(mktemp) || { RUN_SQL_RC=250; return 0; }

    local pw=""
    if [[ -n "$PASSWORD_FILE" ]]; then
        [[ -r "$PASSWORD_FILE" ]] || { RUN_SQL_RC=251; return 0; }
        IFS= read -r pw < "$PASSWORD_FILE" || true
    fi

    if [[ -n "$pw" ]]; then
        MYSQL_PWD="$pw" timeout --kill-after=2 "${TIMEOUT}" \
            "$MYSQL_BIN" "${args[@]}" >"$TMP_OUT" 2>"$TMP_ERR" <<<"$sql" || rc=$?
    else
        timeout --kill-after=2 "${TIMEOUT}" \
            "$MYSQL_BIN" "${args[@]}" >"$TMP_OUT" 2>"$TMP_ERR" <<<"$sql" || rc=$?
    fi

    RUN_SQL_RC=$rc
    RUN_SQL_OUT=$(cat "$TMP_OUT" 2>/dev/null) || true
    RUN_SQL_ERR=$(first_error_line "$TMP_ERR")
    return 0
}

sql_guard() {
    case "$RUN_SQL_RC" in
        0)   return 0 ;;
        124|137) exit_unknown "query timed out after ${TIMEOUT}s" ;;
        250) exit_unknown "cannot create temporary file" ;;
        251) exit_unknown "password file ${PASSWORD_FILE} is not readable" ;;
        *)   exit_unknown "${MYSQL_BIN} failed (rc=${RUN_SQL_RC}): ${RUN_SQL_ERR:-no error text}" ;;
    esac
}

parse_baselines() {
    local spec=$1 pair id val
    [[ -z "$spec" ]] && return 0
    local IFS=','
    for pair in $spec; do
        [[ -z "$pair" ]] && continue
        id=${pair%%=*}
        val=${pair#*=}
        [[ "$pair" == *=* ]] || exit_unknown "--baseline entry '${pair}' is not <id>=<count>"
        is_number "$id"  || exit_unknown "--baseline source id '${id}' is not a number"
        is_number "$val" || exit_unknown "--baseline count '${val}' for source ${id} is not a number"
        BASELINE[$id]=$val
    done
}

parse_ignores() {
    local spec=$1 id
    [[ -z "$spec" ]] && return 0
    local IFS=','
    for id in $spec; do
        [[ -z "$id" ]] && continue
        is_number "$id" || exit_unknown "--ignore-source id '${id}' is not a number"
        IGNORED[$id]=1
    done
}

main() {
    parse_baselines "$BASELINE_SPEC"
    parse_ignores "$IGNORE_SOURCES"

    # status_last_error is the only reliable error signal on this table; the
    # status enum has no 'error' member. See the header.
    local sql="SELECT sync_source_id, SUM(status_last_error <> ''), COUNT(*) \
               FROM priv_sync_replica \
               GROUP BY sync_source_id \
               ORDER BY sync_source_id;"

    run_sql "$sql"
    sql_guard

    if [[ -z "$RUN_SQL_OUT" ]]; then
        echo "${PLUGIN_NAME} OK - no synchro replicas found | replica_errors_total=0"
        exit "${STATE_OK}"
    fi

    local total_errors=0 total_excess=0 sources=0 worst_source="" worst_excess=0
    local line src errs rows baseline excess stale_baselines=0

    while IFS=$'\t' read -r src errs rows; do
        [[ -z "$src" ]] && continue
        is_number "$src" || continue
        [[ -n "${IGNORED[$src]:-}" ]] && continue

        # SUM() over a group with no matching rows yields NULL, not 0.
        [[ "$errs" == "NULL" || -z "$errs" ]] && errs=0
        is_number "$errs" || continue
        is_number "$rows" || rows=0

        sources=$(( sources + 1 ))
        total_errors=$(( total_errors + errs ))

        baseline=${BASELINE[$src]:-$BASELINE_DEFAULT}
        excess=$(( errs - baseline ))
        (( excess < 0 )) && excess=0
        total_excess=$(( total_excess + excess ))

        PERFDATA+=("replica_errors_${src}=${errs};${baseline};;0")

        if (( excess > worst_excess )); then
            worst_excess=$excess
            worst_source=$src
        fi

        if (( errs < baseline )); then
            # Not a fault, but worth saying: a baseline left higher than
            # reality silently absorbs the next regression.
            stale_baselines=$(( stale_baselines + 1 ))
            DETAILS+=("[INFO] source ${src}: ${errs}/${rows} in error, below its baseline of ${baseline} - lower the baseline so a future rise is still caught")
        elif (( excess > 0 )); then
            DETAILS+=("[ALERT] source ${src}: ${errs}/${rows} in error, ${excess} above its baseline of ${baseline}")
        else
            DETAILS+=("[OK] source ${src}: ${errs}/${rows} in error, at its baseline of ${baseline}")
        fi
    done <<<"$RUN_SQL_OUT"

    PERFDATA+=("replica_errors_total=${total_errors}")
    PERFDATA+=("replica_errors_above_baseline=${total_excess};${WARN_THRESHOLD};${CRIT_THRESHOLD};0")

    if is_number "$CRIT_THRESHOLD" && (( total_excess >= CRIT_THRESHOLD )); then
        escalate "${SEV_CRIT}"
    elif (( total_excess >= WARN_THRESHOLD )); then
        escalate "${SEV_WARN}"
    fi

    local label exit_code summary
    case ${SEVERITY} in
        "${SEV_WARN}") label="WARNING";  exit_code=${STATE_WARNING}  ;;
        "${SEV_CRIT}") label="CRITICAL"; exit_code=${STATE_CRITICAL} ;;
        "${SEV_UNKNOWN}") label="UNKNOWN"; exit_code=${STATE_UNKNOWN} ;;
        *)             label="OK";       exit_code=${STATE_OK}       ;;
    esac

    if (( total_excess > 0 )); then
        summary="${total_excess} replica error(s) above baseline across ${sources} source(s); worst is source ${worst_source} (+${worst_excess})"
    else
        summary="${total_errors} replica error(s) across ${sources} source(s), all at or below baseline"
        (( stale_baselines > 0 )) && summary="${summary}; ${stale_baselines} baseline(s) now too high"
    fi

    local out="${PLUGIN_NAME} ${label} - ${summary}"
    if [[ ${#PERFDATA[@]} -gt 0 ]]; then
        out="${out} | ${PERFDATA[*]}"
    fi
    echo "$out"
    local d
    for d in "${DETAILS[@]}"; do echo "$d"; done
    exit "${exit_code}"
}

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -H)                 DB_HOST="${2:-}";          shift 2 ;;
        -P)                 DB_PORT="${2:-}";          shift 2 ;;
        -d)                 DB_NAME="${2:-}";          shift 2 ;;
        -u)                 DB_USER="${2:-}";          shift 2 ;;
        --defaults-file)    DEFAULTS_FILE="${2:-}";    shift 2 ;;
        --password-file)    PASSWORD_FILE="${2:-}";    shift 2 ;;
        --mysql-bin)        MYSQL_BIN="${2:-}";        shift 2 ;;
        --baseline)         BASELINE_SPEC="${2:-}";    shift 2 ;;
        --baseline-default) BASELINE_DEFAULT="${2:-}"; shift 2 ;;
        --ignore-source)    IGNORE_SOURCES="${2:-}";   shift 2 ;;
        -w)                 WARN_THRESHOLD="${2:-}";   shift 2 ;;
        -c)                 CRIT_THRESHOLD="${2:-}";   shift 2 ;;
        -t|--timeout)       TIMEOUT="${2:-}";          shift 2 ;;
        -V|--version)       echo "${PLUGIN_NAME} v${PLUGIN_VERSION}"; exit "${STATE_OK}" ;;
        -h|--help)          usage ;;
        *)
            echo "${PLUGIN_NAME} UNKNOWN - Unrecognized option: $1"
            exit "${STATE_UNKNOWN}"
            ;;
    esac
done

[[ -n "$DB_NAME" ]] || exit_unknown "Database name (-d) must not be empty"

if [[ -n "$DEFAULTS_FILE" && ! -r "$DEFAULTS_FILE" ]]; then
    exit_unknown "defaults file ${DEFAULTS_FILE} is not readable by $(id -un)"
fi

for v in DB_PORT BASELINE_DEFAULT WARN_THRESHOLD TIMEOUT; do
    is_number "${!v}" || exit_unknown "${v} must be a non-negative integer"
done

if [[ -n "$CRIT_THRESHOLD" ]]; then
    is_number "$CRIT_THRESHOLD" || exit_unknown "-c must be a non-negative integer"
    (( WARN_THRESHOLD < CRIT_THRESHOLD )) || \
        exit_unknown "Warning threshold (${WARN_THRESHOLD}) must be less than critical (${CRIT_THRESHOLD})"
fi

(( WARN_THRESHOLD > 0 )) || exit_unknown "-w must be at least 1 (0 would alert at the baseline itself)"

check_dependencies
main
