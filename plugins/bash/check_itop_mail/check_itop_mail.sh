#!/usr/bin/env bash
# MIT License
# Copyright (c) 2025 ISW Kudos
# https://github.com/isw-kudos/icinga-plugins/blob/main/LICENSE
#
# check_itop_mail - is iTop's mail actually leaving, and not going to a sink?
#
# Two independent assertions, at two severities:
#
#   1. CONFIG (CRITICAL). The configured transport still sends mail off the
#      host, and the relay is not a local capture sink. A migration commonly
#      leaves the instance pointed at a mail catcher; every notification then
#      disappears in complete silence, with no error anywhere.
#
#   2. DATABASE (WARNING). No send failures were logged in the last window.
#
# Note the direction of assertion 1. A deploy-time script asserts mail must be
# trapped; in production the assertion inverts - mail must be able to leave.
# Running the deploy-time direction against a live instance is how a check ends
# up crying wolf on the expected state, and a check that does that gets ignored.

set -euo pipefail

PLUGIN_NAME="check_itop_mail"
PLUGIN_VERSION="1.0.0"

# --- Defaults ---
CONFIG_FILE=""
EXPECT_TRANSPORT="SMTP"
FORBID_HOSTS=()
EXPECT_VERIFY_PEER=""     # empty = do not assert
DO_CONFIG=1
DO_DB=1

DB_HOST="127.0.0.1"
DB_PORT="3306"
DB_NAME="itop"
DB_USER=""
DEFAULTS_FILE=""
PASSWORD_FILE=""
MYSQL_BIN=""
WINDOW_HOURS=1
FAILURE_PREFIX="Sending eMail failed"
WARN_THRESHOLD=1
CRIT_THRESHOLD=""
TIMEOUT=30

# --- Exit Codes ---
STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3

# Internal severity, ordered so a real fault outranks an UNKNOWN: a database
# that cannot be reached must not mask a config pointing at a sink.
SEV_OK=0
SEV_UNKNOWN=1
SEV_WARN=2
SEV_CRIT=3
SEVERITY=${SEV_OK}

SUMMARY=()
DETAILS=()
PERFDATA=()

RUN_SQL_OUT=""
RUN_SQL_ERR=""
RUN_SQL_RC=0

TMP_OUT=""
TMP_ERR=""
trap 'rm -f -- "$TMP_OUT" "$TMP_ERR" 2>/dev/null || true' EXIT

usage() {
    cat <<EOF
Usage: ${PLUGIN_NAME} [--config <path>] [--expect-transport <name>]
                      [--forbid-host <host>]... [--expect-verify-peer <0|1>]
                      [-H <host>] [-P <port>] [-d <database>]
                      [--defaults-file <path> | --password-file <path>] [-u <user>]
                      [--window-hours <n>] [--failure-prefix <text>]
                      [--no-config] [--no-db] [-w <n>] [-c <n>]
                      [-t <seconds>] [-V] [-h]

Config assertions (CRITICAL):
      --config              Path to config-itop.php    [required unless --no-config]
      --expect-transport    Transport that means mail leaves the host
                            (default: ${EXPECT_TRANSPORT}). Anything else - LogFile,
                            Null - means notifications go nowhere.
      --forbid-host         Relay hostname that is a capture sink, e.g. 'mailpit'.
                            Repeatable. Matched case-insensitively.
      --expect-verify-peer  Assert email_transport_smtp.verify_peer is 0 or 1.
                            Omit to skip. An ABSENT setting is reported when this
                            is used, because it breaks the STARTTLS handshake.
      --no-config           Skip the config half entirely

Database assertions (WARNING):
  -H, -P, -d, -u            Database connection
      --defaults-file       my.cnf-style credentials file. There is deliberately
                            no -p option: a command-line password is visible in
                            the process list.
      --password-file       Alternative: file whose first line is the password
      --mysql-bin           Client binary (default: mysql, then mariadb)
      --window-hours        How far back to look (default: ${WINDOW_HOURS})
      --failure-prefix      priv_event.message prefix that marks a real failure
                            (default: '${FAILURE_PREFIX}')
      --no-db               Skip the database half entirely
  -w                        Warning threshold, failure count (default: ${WARN_THRESHOLD})
  -c                        Critical threshold (default: unset)

  -t, --timeout             Query timeout in seconds (default: ${TIMEOUT})
  -V, --version             Show version
  -h, --help                Show this help

Exit codes: 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN
EOF
    exit "${STATE_UNKNOWN}"
}

is_number() { [[ "$1" =~ ^[0-9]+$ ]]; }

escalate() { local lvl=$1; if (( lvl > SEVERITY )); then SEVERITY=$lvl; fi; }

record() {
    local lvl=$1 short=$2 detail=$3
    local tag
    case $lvl in
        "${SEV_OK}")   tag="OK"      ;;
        "${SEV_WARN}") tag="WARN"    ;;
        "${SEV_CRIT}") tag="CRIT"    ;;
        *)             tag="UNKNOWN" ;;
    esac
    SUMMARY+=("${short}=${tag}")
    DETAILS+=("[${tag}] ${detail}")
    escalate "$lvl"
}

exit_unknown() {
    echo "${PLUGIN_NAME} UNKNOWN - $1"
    exit "${STATE_UNKNOWN}"
}

# php_config_get FILE KEY
# Extracts a scalar from a config-itop.php $MySettings array without running
# PHP, which is not installed on the Docker host - the interpreter lives inside
# the application container. Keys are matched literally (they contain dots), so
# nothing here depends on regex escaping.
php_config_get() {
    local file=$1 key=$2
    awk -v k="$key" '
        BEGIN { q = sprintf("%c", 39); found = 0 }
        {
            for (v = 1; v <= 2; v++) {
                pat = (v == 1) ? q k q : "\"" k "\""
                p = index($0, pat)
                if (p == 0) continue
                rest = substr($0, p + length(pat))
                if (rest !~ /^[ \t]*=>/) continue
                sub(/^[ \t]*=>[ \t]*/, "", rest)
                sub(/[ \t]*,[ \t]*$/, "", rest)
                sub(/[ \t]+$/, "", rest)
                if (length(rest) > 1) {
                    if (substr(rest,1,1) == "\"" && substr(rest,length(rest),1) == "\"")
                        rest = substr(rest, 2, length(rest) - 2)
                    else if (substr(rest,1,1) == q && substr(rest,length(rest),1) == q)
                        rest = substr(rest, 2, length(rest) - 2)
                }
                val = rest; found = 1
            }
        }
        END { if (found) print val }
    ' "$file"
}

# php_config_has FILE KEY -> rc 0 if the key appears at all
php_config_has() {
    local file=$1 key=$2
    awk -v k="$key" '
        BEGIN { q = sprintf("%c", 39); rc = 1 }
        {
            for (v = 1; v <= 2; v++) {
                pat = (v == 1) ? q k q : "\"" k "\""
                p = index($0, pat)
                if (p == 0) continue
                rest = substr($0, p + length(pat))
                if (rest ~ /^[ \t]*=>/) rc = 0
            }
        }
        END { exit rc }
    ' "$file"
}

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

check_dependencies() {
    command -v awk >/dev/null 2>&1 || exit_unknown "Required command not found: awk"
    command -v timeout >/dev/null 2>&1 || exit_unknown "Required command not found: timeout"
    if [[ "$DO_DB" -eq 1 ]]; then
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
    fi
}

check_config() {
    if [[ ! -e "$CONFIG_FILE" ]]; then
        record "${SEV_UNKNOWN}" "config" "${CONFIG_FILE} does not exist"
        PERFDATA+=("mail_sink=U")
        return
    fi
    if [[ ! -r "$CONFIG_FILE" ]]; then
        # config-itop.php is typically mode 440 owned by the web user, so this
        # is a monitoring permissions problem, not a verdict about the config.
        record "${SEV_UNKNOWN}" "config" "${CONFIG_FILE} is not readable by $(id -un)"
        PERFDATA+=("mail_sink=U")
        return
    fi

    local transport host
    transport=$(php_config_get "$CONFIG_FILE" "email_transport")
    host=$(php_config_get "$CONFIG_FILE" "email_transport_smtp.host")

    if [[ -z "$transport" ]]; then
        record "${SEV_UNKNOWN}" "config" "email_transport is not set in ${CONFIG_FILE}"
        PERFDATA+=("mail_sink=U")
        return
    fi

    # A transport other than the expected one - LogFile, Null - means mail never
    # reaches a network at all.
    if [[ "$transport" != "$EXPECT_TRANSPORT" ]]; then
        record "${SEV_CRIT}" "config" \
            "email_transport is '${transport}', expected '${EXPECT_TRANSPORT}' - notifications are not leaving this host"
        PERFDATA+=("mail_sink=1")
        return
    fi

    local forbidden="" f lc_host lc_f
    lc_host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
    for f in ${FORBID_HOSTS[@]+"${FORBID_HOSTS[@]}"}; do
        lc_f=$(printf '%s' "$f" | tr '[:upper:]' '[:lower:]')
        if [[ "$lc_host" == "$lc_f" ]]; then
            forbidden=$f
            break
        fi
    done

    if [[ -n "$forbidden" ]]; then
        record "${SEV_CRIT}" "config" \
            "relay is '${host}', a configured capture sink - every notification is being swallowed"
        PERFDATA+=("mail_sink=1")
        return
    fi

    PERFDATA+=("mail_sink=0")

    # verify_peer is only asserted when asked. An absent value is worse than a
    # wrong one: the STARTTLS handshake fails and no mail goes out at all.
    if [[ -n "$EXPECT_VERIFY_PEER" ]]; then
        if ! php_config_has "$CONFIG_FILE" "email_transport_smtp.verify_peer"; then
            record "${SEV_WARN}" "config" \
                "relay is '${host}' but email_transport_smtp.verify_peer is absent - STARTTLS will fail"
            return
        fi
        local vp norm
        vp=$(php_config_get "$CONFIG_FILE" "email_transport_smtp.verify_peer")
        case "$vp" in
            true|1)  norm=1 ;;
            false|0) norm=0 ;;
            *)       norm="$vp" ;;
        esac
        if [[ "$norm" != "$EXPECT_VERIFY_PEER" ]]; then
            record "${SEV_WARN}" "config" \
                "relay is '${host}', verify_peer is '${vp}' but ${EXPECT_VERIFY_PEER} was expected"
            return
        fi
    fi

    record "${SEV_OK}" "config" "transport ${transport}, relay '${host}' is not a sink"
}

check_db() {
    local sql count
    printf -v sql '%s' \
        "SELECT COUNT(*) FROM priv_event \
         WHERE message LIKE '${FAILURE_PREFIX//\'/\'\'}%' \
           AND date > NOW() - INTERVAL ${WINDOW_HOURS} HOUR;"

    run_sql "$sql"

    case "$RUN_SQL_RC" in
        0) ;;
        124|137)
            record "${SEV_UNKNOWN}" "sends" "query timed out after ${TIMEOUT}s"
            PERFDATA+=("email_failures=U;${WARN_THRESHOLD};${CRIT_THRESHOLD};0"); return ;;
        250)
            record "${SEV_UNKNOWN}" "sends" "cannot create temporary file"
            PERFDATA+=("email_failures=U;${WARN_THRESHOLD};${CRIT_THRESHOLD};0"); return ;;
        251)
            record "${SEV_UNKNOWN}" "sends" "password file ${PASSWORD_FILE} is not readable"
            PERFDATA+=("email_failures=U;${WARN_THRESHOLD};${CRIT_THRESHOLD};0"); return ;;
        *)
            record "${SEV_UNKNOWN}" "sends" "${MYSQL_BIN} failed (rc=${RUN_SQL_RC}): ${RUN_SQL_ERR:-no error text}"
            PERFDATA+=("email_failures=U;${WARN_THRESHOLD};${CRIT_THRESHOLD};0"); return ;;
    esac

    count=$(printf '%s' "$RUN_SQL_OUT" | head -n1 | cut -f1)
    if ! is_number "$count"; then
        record "${SEV_UNKNOWN}" "sends" "unexpected result for the failure count: '${count}'"
        PERFDATA+=("email_failures=U;${WARN_THRESHOLD};${CRIT_THRESHOLD};0")
        return
    fi

    PERFDATA+=("email_failures=${count};${WARN_THRESHOLD};${CRIT_THRESHOLD};0")

    if is_number "$CRIT_THRESHOLD" && (( count >= CRIT_THRESHOLD )); then
        record "${SEV_CRIT}" "sends" "${count} send failure(s) in the last ${WINDOW_HOURS}h"
    elif (( count >= WARN_THRESHOLD )); then
        record "${SEV_WARN}" "sends" "${count} send failure(s) in the last ${WINDOW_HOURS}h"
    else
        record "${SEV_OK}" "sends" "no send failures in the last ${WINDOW_HOURS}h"
    fi
}

main() {
    [[ "$DO_CONFIG" -eq 1 ]] && check_config
    [[ "$DO_DB" -eq 1 ]] && check_db

    local label exit_code
    case ${SEVERITY} in
        "${SEV_WARN}")    label="WARNING";  exit_code=${STATE_WARNING}  ;;
        "${SEV_CRIT}")    label="CRITICAL"; exit_code=${STATE_CRITICAL} ;;
        "${SEV_UNKNOWN}") label="UNKNOWN";  exit_code=${STATE_UNKNOWN}  ;;
        *)                label="OK";       exit_code=${STATE_OK}       ;;
    esac

    local out="${PLUGIN_NAME} ${label} - ${SUMMARY[*]}"
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
        --config)             CONFIG_FILE="${2:-}";        shift 2 ;;
        --expect-transport)   EXPECT_TRANSPORT="${2:-}";   shift 2 ;;
        --forbid-host)        FORBID_HOSTS+=("${2:-}");    shift 2 ;;
        --expect-verify-peer) EXPECT_VERIFY_PEER="${2:-}"; shift 2 ;;
        --no-config)          DO_CONFIG=0;                 shift ;;
        --no-db)              DO_DB=0;                     shift ;;
        -H)                   DB_HOST="${2:-}";            shift 2 ;;
        -P)                   DB_PORT="${2:-}";            shift 2 ;;
        -d)                   DB_NAME="${2:-}";            shift 2 ;;
        -u)                   DB_USER="${2:-}";            shift 2 ;;
        --defaults-file)      DEFAULTS_FILE="${2:-}";      shift 2 ;;
        --password-file)      PASSWORD_FILE="${2:-}";      shift 2 ;;
        --mysql-bin)          MYSQL_BIN="${2:-}";          shift 2 ;;
        --window-hours)       WINDOW_HOURS="${2:-}";       shift 2 ;;
        --failure-prefix)     FAILURE_PREFIX="${2:-}";     shift 2 ;;
        -w)                   WARN_THRESHOLD="${2:-}";     shift 2 ;;
        -c)                   CRIT_THRESHOLD="${2:-}";     shift 2 ;;
        -t|--timeout)         TIMEOUT="${2:-}";            shift 2 ;;
        -V|--version)         echo "${PLUGIN_NAME} v${PLUGIN_VERSION}"; exit "${STATE_OK}" ;;
        -h|--help)            usage ;;
        *)
            echo "${PLUGIN_NAME} UNKNOWN - Unrecognized option: $1"
            exit "${STATE_UNKNOWN}"
            ;;
    esac
done

if [[ "$DO_CONFIG" -eq 0 && "$DO_DB" -eq 0 ]]; then
    exit_unknown "--no-config and --no-db together leave nothing to check"
fi

if [[ "$DO_CONFIG" -eq 1 && -z "$CONFIG_FILE" ]]; then
    exit_unknown "--config is required unless --no-config is given"
fi

if [[ -n "$EXPECT_VERIFY_PEER" && "$EXPECT_VERIFY_PEER" != "0" && "$EXPECT_VERIFY_PEER" != "1" ]]; then
    exit_unknown "--expect-verify-peer must be 0 or 1"
fi

if [[ -n "$DEFAULTS_FILE" && ! -r "$DEFAULTS_FILE" ]]; then
    exit_unknown "defaults file ${DEFAULTS_FILE} is not readable by $(id -un)"
fi

for v in DB_PORT WINDOW_HOURS WARN_THRESHOLD TIMEOUT; do
    is_number "${!v}" || exit_unknown "${v} must be a non-negative integer"
done

if [[ -n "$CRIT_THRESHOLD" ]]; then
    is_number "$CRIT_THRESHOLD" || exit_unknown "-c must be a non-negative integer"
    (( WARN_THRESHOLD < CRIT_THRESHOLD )) || \
        exit_unknown "Warning threshold (${WARN_THRESHOLD}) must be less than critical (${CRIT_THRESHOLD})"
fi

check_dependencies
main
