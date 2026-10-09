#!/usr/bin/env bash
# MIT License
# Copyright (c) 2025 ISW Kudos
# https://github.com/isw-kudos/icinga-plugins/blob/main/LICENSE
#
# check_itop_cron - is iTop's background task runner actually processing?
#
# The itop-cron container being up says the process started. This says it is
# doing its job. When itop-cron stops processing, notifications stop going out
# and there is no other symptom: tickets still work, the UI is fine, and nobody
# hears anything.
#
# Known blind spot, by construction: zero overdue tasks is equally true when
# cron is healthy and when cron is dead with an empty queue. Detection therefore
# lags a stall by --stale-hours. That is acceptable - the alternative would be a
# last-run timestamp iTop does not reliably expose - but it should be understood
# rather than discovered.

set -euo pipefail

PLUGIN_NAME="check_itop_cron"
PLUGIN_VERSION="1.0.0"

# --- Defaults ---
DB_HOST="127.0.0.1"
DB_PORT="3306"
DB_NAME="itop"
DB_USER=""
DEFAULTS_FILE=""
PASSWORD_FILE=""
MYSQL_BIN=""
STALE_HOURS=1
PLANNED_COLUMN="planned"
WARN_THRESHOLD=1
CRIT_THRESHOLD=""      # empty disables the CRITICAL comparison entirely
TIMEOUT=30

# --- Exit Codes ---
STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3

# run_sql results (globals, so the caller is not a $() subshell and the rc
# survives without tripping `set -e`).
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
                      [--stale-hours <n>] [--planned-column <name>]
                      [-w <n>] [-c <n>] [-t <seconds>] [-V] [-h]

Counts iTop background tasks that are still 'planned' well after they were due.

Options:
  -H               Database host (default: ${DB_HOST})
  -P               Database port (default: ${DB_PORT})
  -d               Database name (default: ${DB_NAME})
  -u               Database user (omit if the defaults file supplies it)
      --defaults-file  my.cnf-style file holding the credentials. This is the
                       recommended way to pass a password: there is deliberately
                       no -p option, because a password on the command line is
                       visible in the process list and ends up in a CheckCommand.
      --password-file  Alternative: a file whose first line is the password.
      --mysql-bin      Client binary to use (default: mysql, then mariadb)
      --stale-hours    How far past due a task must be to count (default: ${STALE_HOURS})
      --planned-column Column holding the scheduled time (default: ${PLANNED_COLUMN}).
                       iTop versions disagree - some use 'planned_date'. Confirm
                       with: SHOW CREATE TABLE ${DB_NAME}.priv_async_task
  -w               Warning threshold, overdue task count (default: ${WARN_THRESHOLD})
  -c               Critical threshold, overdue task count (default: unset, never CRITICAL)
  -t, --timeout    Query timeout in seconds (default: ${TIMEOUT})
  -V, --version    Show version
  -h, --help       Show this help

Exit codes: 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN
EOF
    exit "${STATE_UNKNOWN}"
}

is_number() { [[ "$1" =~ ^[0-9]+$ ]]; }

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

# run_sql <sql>
#   RUN_SQL_RC : 0 = the server answered; 124/137 = timed out; anything else =
#                client, connection or permission failure. Callers MUST treat a
#                non-zero rc as UNKNOWN and must not read RUN_SQL_OUT.
#   RUN_SQL_OUT: tab-separated rows, no header. Empty with rc 0 means zero rows,
#                unambiguously - errors go to stderr and set a non-zero rc.
run_sql() {
    local sql=$1 rc=0
    local args=()

    RUN_SQL_OUT=""; RUN_SQL_ERR=""; RUN_SQL_RC=0

    # --defaults-file must be the FIRST argument the client sees. When none is
    # given, --no-defaults is passed explicitly so the check can never silently
    # succeed on the icinga user's own ~/.my.cnf and then break the day that
    # file changes.
    if [[ -n "$DEFAULTS_FILE" ]]; then
        args+=("--defaults-file=${DEFAULTS_FILE}")
    else
        args+=("--no-defaults")
    fi
    args+=(
        --batch                 # tab-separated, no box drawing
        --skip-column-names
        "--connect-timeout=${TIMEOUT}"
        "--host=${DB_HOST}"
        "--port=${DB_PORT}"
        "--database=${DB_NAME}"
    )
    [[ -n "$DB_USER" ]] && args+=("--user=${DB_USER}")

    TMP_OUT=$(mktemp) || { RUN_SQL_RC=250; return 0; }
    TMP_ERR=$(mktemp) || { RUN_SQL_RC=250; return 0; }

    # The password reaches the client through the environment, never argv:
    # MYSQL_PWD is readable only via /proc/<pid>/environ (same uid or root),
    # whereas -p<pw> is in ps(1) output for every user on the box.
    #
    # The query is fed on stdin, which also guarantees EOF - a bad credential
    # can never park the plugin on an interactive password prompt until the
    # timeout fires.
    #
    # No 2>&1: the client writes "[Warning] ..." lines to stderr that would
    # otherwise be parsed as data rows. No --raw either: default batch escaping
    # is what stops a value containing a newline forging an extra row.
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

# first_error_line FILE
# The client prefixes its stderr with deprecation notices - MariaDB 11 emits
# "WARNING: option --ssl-verify-server-cert is deprecated" on every connection.
# A plain `head -n1` would surface that instead of "Access denied" or "Can't
# connect", so the real error is preferred and the warnings are a fallback.
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

# Maps a run_sql failure to an UNKNOWN exit. Never returns on failure.
sql_guard() {
    case "$RUN_SQL_RC" in
        0)   return 0 ;;
        124|137) exit_unknown "query timed out after ${TIMEOUT}s" ;;
        250) exit_unknown "cannot create temporary file" ;;
        251) exit_unknown "password file ${PASSWORD_FILE} is not readable" ;;
        *)   exit_unknown "${MYSQL_BIN} failed (rc=${RUN_SQL_RC}): ${RUN_SQL_ERR:-no error text}" ;;
    esac
}

main() {
    local sql count oldest
    # The column name is validated as a bare identifier before interpolation,
    # and everything else in the statement is a literal integer.
    printf -v sql '%s' \
        "SELECT COUNT(*), COALESCE(MAX(TIMESTAMPDIFF(HOUR, ${PLANNED_COLUMN}, NOW())), 0) \
         FROM priv_async_task \
         WHERE status = 'planned' \
           AND ${PLANNED_COLUMN} IS NOT NULL \
           AND ${PLANNED_COLUMN} < NOW() - INTERVAL ${STALE_HOURS} HOUR;"

    run_sql "$sql"
    sql_guard

    [[ -n "$RUN_SQL_OUT" ]] || \
        exit_unknown "query returned no rows - is priv_async_task present in ${DB_NAME}?"

    count=$(printf '%s' "$RUN_SQL_OUT" | head -n1 | cut -f1)
    oldest=$(printf '%s' "$RUN_SQL_OUT" | head -n1 | cut -f2)

    # MAX() over zero rows yields NULL; COALESCE handles it server-side, but a
    # literal NULL reaching here would break is_number and the (( )) below.
    [[ "$oldest" == "NULL" ]] && oldest=0

    is_number "$count" || \
        exit_unknown "unexpected result for the overdue task count: '${count}'"
    is_number "$oldest" || oldest=0

    local perfdata="overdue_tasks=${count};${WARN_THRESHOLD};${CRIT_THRESHOLD};0 oldest_overdue_hours=${oldest}"

    if is_number "$CRIT_THRESHOLD" && (( count >= CRIT_THRESHOLD )); then
        echo "${PLUGIN_NAME} CRITICAL - ${count} task(s) still planned more than ${STALE_HOURS}h past due (oldest ${oldest}h) - itop-cron is not processing | ${perfdata}"
        exit "${STATE_CRITICAL}"
    elif (( count >= WARN_THRESHOLD )); then
        echo "${PLUGIN_NAME} WARNING - ${count} task(s) still planned more than ${STALE_HOURS}h past due (oldest ${oldest}h) - itop-cron is not processing | ${perfdata}"
        exit "${STATE_WARNING}"
    fi

    echo "${PLUGIN_NAME} OK - no tasks overdue by more than ${STALE_HOURS}h | ${perfdata}"
    exit "${STATE_OK}"
}

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -H)               DB_HOST="${2:-}";        shift 2 ;;
        -P)               DB_PORT="${2:-}";        shift 2 ;;
        -d)               DB_NAME="${2:-}";        shift 2 ;;
        -u)               DB_USER="${2:-}";        shift 2 ;;
        --defaults-file)  DEFAULTS_FILE="${2:-}";  shift 2 ;;
        --password-file)  PASSWORD_FILE="${2:-}";  shift 2 ;;
        --mysql-bin)      MYSQL_BIN="${2:-}";      shift 2 ;;
        --stale-hours)    STALE_HOURS="${2:-}";    shift 2 ;;
        --planned-column) PLANNED_COLUMN="${2:-}"; shift 2 ;;
        -w)               WARN_THRESHOLD="${2:-}"; shift 2 ;;
        -c)               CRIT_THRESHOLD="${2:-}"; shift 2 ;;
        -t|--timeout)     TIMEOUT="${2:-}";        shift 2 ;;
        -V|--version)     echo "${PLUGIN_NAME} v${PLUGIN_VERSION}"; exit "${STATE_OK}" ;;
        -h|--help)        usage ;;
        *)
            echo "${PLUGIN_NAME} UNKNOWN - Unrecognized option: $1"
            exit "${STATE_UNKNOWN}"
            ;;
    esac
done

[[ -n "$DB_NAME" ]] || exit_unknown "Database name (-d) must not be empty"

# Interpolated into the statement, so it must be a bare identifier.
[[ "$PLANNED_COLUMN" =~ ^[A-Za-z0-9_]+$ ]] || \
    exit_unknown "--planned-column must be a bare column name"

if [[ -n "$DEFAULTS_FILE" && ! -r "$DEFAULTS_FILE" ]]; then
    exit_unknown "defaults file ${DEFAULTS_FILE} is not readable by $(id -un)"
fi

for v in DB_PORT STALE_HOURS WARN_THRESHOLD TIMEOUT; do
    is_number "${!v}" || exit_unknown "${v} must be a non-negative integer"
done

if [[ -n "$CRIT_THRESHOLD" ]]; then
    is_number "$CRIT_THRESHOLD" || exit_unknown "-c must be a non-negative integer"
    (( WARN_THRESHOLD < CRIT_THRESHOLD )) || \
        exit_unknown "Warning threshold (${WARN_THRESHOLD}) must be less than critical (${CRIT_THRESHOLD})"
fi

check_dependencies
main
