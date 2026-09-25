#!/usr/bin/env bash
# MIT License
# Copyright (c) 2025 ISW Kudos
# https://github.com/isw-kudos/icinga-plugins/blob/main/LICENSE
#
# check_file_age - age of the NEWEST file matching a glob in a directory.
#
# This check exists to detect ABSENCE. A scheduled job that never runs produces
# no output, no exit code and no log line, so there is nothing for a
# conventional check to notice. Here, "no file matches" is a first-class
# CRITICAL result rather than an error, and so is "the directory is not there"
# (an unmounted backup volume provably holds no backup).
#
# The one case that is NOT an alert about the data is "the directory exists but
# this user cannot read it" - that is a monitoring permissions problem, and it
# returns UNKNOWN so it cannot be mistaken for a verdict about the backups.

set -euo pipefail

PLUGIN_NAME="check_file_age"
PLUGIN_VERSION="1.0.0"

# --- Defaults ---
DIR=""
PATTERN=""
WARN_HOURS=26
CRIT_HOURS=50
MIN_BYTES=1
TIMEOUT=30

# --- Exit Codes ---
STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3

# Scratch files, cleaned up by the EXIT trap. Globals rather than locals so the
# trap can still see them.
TMP_OUT=""
TMP_ERR=""
trap 'rm -f -- "$TMP_OUT" "$TMP_ERR" 2>/dev/null || true' EXIT

usage() {
    cat <<EOF
Usage: ${PLUGIN_NAME} -p <directory> --pattern <glob> [-w <hours>] [-c <hours>]
                      [--min-bytes <n>] [-t <seconds>] [-V] [-h]

Checks the age of the newest file matching a glob. Alerts when that file is too
old, when it is implausibly small, or when no such file exists at all.

Options:
  -p, --path       Directory to look in (not recursive)              [required]
      --pattern    Filename glob, e.g. 'itop-db-*.sql.gz'            [required]
                   A basename pattern - it must not contain '/'.
  -w               Warning threshold, age in hours (default: ${WARN_HOURS})
  -c               Critical threshold, age in hours (default: ${CRIT_HOURS})
      --min-bytes  Newest match smaller than this is CRITICAL (default: ${MIN_BYTES}).
                   Catches a truncated or empty dump, which is otherwise fresh
                   and would report OK.
  -t, --timeout    Timeout in seconds for the directory scan (default: ${TIMEOUT})
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

exit_critical() {
    echo "${PLUGIN_NAME} CRITICAL - $1${2:+ | $2}"
    exit "${STATE_CRITICAL}"
}

check_dependencies() {
    for cmd in find timeout; do
        command -v "${cmd}" >/dev/null 2>&1 || \
            exit_unknown "Required command not found: ${cmd}"
    done
}

main() {
    local warn_s crit_s
    warn_s=$(( WARN_HOURS * 3600 ))
    crit_s=$(( CRIT_HOURS * 3600 ))

    # --- Pre-flight -------------------------------------------------------
    # These four conditions are tested explicitly rather than inferred from
    # find's behaviour, because CRITICAL (there is no backup) and UNKNOWN (we
    # cannot tell) must never be confused with one another.
    if [[ ! -e "$DIR" ]]; then
        exit_critical "directory ${DIR} does not exist - nothing is being written there"
    elif [[ ! -d "$DIR" ]]; then
        exit_unknown "${DIR} is not a directory"
    elif [[ ! -r "$DIR" || ! -x "$DIR" ]]; then
        # -r alone is not enough: traversing a directory to stat its entries
        # needs -x as well.
        exit_unknown "${DIR} is not readable by $(id -un) - cannot assert absence"
    fi

    # --- Enumerate --------------------------------------------------------
    # The pattern is handed to find as a quoted -name argument, so the shell
    # never expands it: no eval, no word-splitting, no accidental globbing.
    # stdout and stderr are captured separately so that "no match" (rc 0, empty
    # stdout) can never be confused with "the scan failed".
    TMP_OUT=$(mktemp) || exit_unknown "cannot create temporary file"
    TMP_ERR=$(mktemp) || exit_unknown "cannot create temporary file"

    local rc=0
    timeout --kill-after=2 "${TIMEOUT}" \
        find -L "$DIR" -maxdepth 1 -type f -name "$PATTERN" -printf '%T@ %s %p\0' \
        >"$TMP_OUT" 2>"$TMP_ERR" || rc=$?

    if [[ $rc -eq 124 || $rc -eq 137 ]]; then
        exit_unknown "scanning ${DIR} timed out after ${TIMEOUT}s"
    fi
    # -maxdepth 1 means there are no subdirectories to stumble over, so any
    # stderr at all is an anomaly worth reporting rather than ignoring.
    if [[ $rc -ne 0 || -s "$TMP_ERR" ]]; then
        exit_unknown "scanning ${DIR} failed (rc=${rc}): $(head -n1 "$TMP_ERR")"
    fi

    # --- Pick the newest --------------------------------------------------
    local newest_path="" newest_mtime=0 newest_size=0 match_count=0
    local rec ts rest size path
    while IFS= read -r -d '' rec; do
        ts=${rec%% *}
        rest=${rec#* }
        size=${rest%% *}
        path=${rest#* }
        ts=${ts%%.*}                      # %T@ is seconds.fraction
        is_number "$ts" || continue
        is_number "$size" || continue
        # NOT (( match_count++ )): that returns rc 1 on the 0 -> 1 step, which
        # under `set -e` would exit the plugin with status 1 (WARNING).
        match_count=$(( match_count + 1 ))
        if (( ts > newest_mtime )); then
            newest_mtime=$ts
            newest_size=$size
            newest_path=$path
        fi
    done <"$TMP_OUT"

    if (( match_count == 0 )); then
        exit_critical \
            "no file matching '${PATTERN}' in ${DIR} - the job produced nothing" \
            "age_seconds=U;${warn_s};${crit_s};0 matched_files=0"
    fi

    # --- Age --------------------------------------------------------------
    local now age
    now=$(date +%s)
    age=$(( now - newest_mtime ))
    (( age < 0 )) && age=0             # clock skew

    local name perfdata
    name=$(basename "$newest_path")
    perfdata="age_seconds=${age}s;${warn_s};${crit_s};0 matched_files=${match_count} newest_bytes=${newest_size}B"

    local age_h=$(( age / 3600 ))

    if (( newest_size < MIN_BYTES )); then
        exit_critical \
            "newest match ${name} is ${newest_size} bytes (minimum ${MIN_BYTES}) - truncated or empty" \
            "$perfdata"
    fi

    if (( age >= crit_s )); then
        echo "${PLUGIN_NAME} CRITICAL - ${name} is ${age_h}h old (critical at ${CRIT_HOURS}h) | ${perfdata}"
        exit "${STATE_CRITICAL}"
    elif (( age >= warn_s )); then
        echo "${PLUGIN_NAME} WARNING - ${name} is ${age_h}h old (warning at ${WARN_HOURS}h) | ${perfdata}"
        exit "${STATE_WARNING}"
    fi

    echo "${PLUGIN_NAME} OK - ${name} is ${age_h}h old, ${match_count} match(es) | ${perfdata}"
    exit "${STATE_OK}"
}

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--path)    DIR="${2:-}";        shift 2 ;;
        --pattern)    PATTERN="${2:-}";    shift 2 ;;
        -w)           WARN_HOURS="${2:-}"; shift 2 ;;
        -c)           CRIT_HOURS="${2:-}"; shift 2 ;;
        --min-bytes)  MIN_BYTES="${2:-}";  shift 2 ;;
        -t|--timeout) TIMEOUT="${2:-}";    shift 2 ;;
        -V|--version) echo "${PLUGIN_NAME} v${PLUGIN_VERSION}"; exit "${STATE_OK}" ;;
        -h|--help)    usage ;;
        *)
            echo "${PLUGIN_NAME} UNKNOWN - Unrecognized option: $1"
            exit "${STATE_UNKNOWN}"
            ;;
    esac
done

[[ -n "$DIR" ]]     || exit_unknown "Option -p/--path is required"
[[ -n "$PATTERN" ]] || exit_unknown "Option --pattern is required"

case "$PATTERN" in
    */*) exit_unknown "--pattern must be a filename glob, not a path" ;;
esac

for v in WARN_HOURS CRIT_HOURS MIN_BYTES TIMEOUT; do
    is_number "${!v}" || exit_unknown "${v} must be a non-negative integer"
done

(( WARN_HOURS < CRIT_HOURS )) || \
    exit_unknown "Warning threshold (${WARN_HOURS}h) must be less than critical (${CRIT_HOURS}h)"

check_dependencies
main
