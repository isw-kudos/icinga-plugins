#!/usr/bin/env bash
# MIT License
# Copyright (c) 2025 ISW Kudos
# https://github.com/isw-kudos/icinga-plugins/blob/main/LICENSE
#
# check_archive_integrity - is the newest archive a file worth having?
#
# A freshness check proves that a file appeared. This proves the bytes are
# intact and that the job reached its final step. The two are different
# failures and are reported at different severities: a corrupt archive is
# CRITICAL, a missing checksum sidecar is WARNING (the archive is fine; the
# script that wrote it regressed).
#
# The decompression test is read-only - it decompresses to /dev/null, so it
# costs CPU and no disk.
#
# Concurrency: testing an archive that is still being written fails reliably
# with "unexpected end of file". Rather than depend on being scheduled outside
# the backup window - a window that drifts as the dump grows - this check only
# ever tests an archive older than --min-age-seconds.

set -euo pipefail

PLUGIN_NAME="check_archive_integrity"
PLUGIN_VERSION="1.0.0"

# --- Defaults ---
DIR=""
PATTERN=""
SIDECAR_EXT=".sha256"
MIN_AGE_SECONDS=300
TIMEOUT=300

# --- Exit Codes ---
STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3

# Internal severity, ordered so CRITICAL outranks WARNING and both outrank
# UNKNOWN. The house escalate() idiom ranks UNKNOWN (3) highest, which here
# would let "cannot read the sidecar" mask "the archive is corrupt".
SEV_OK=0
SEV_UNKNOWN=1
SEV_WARN=2
SEV_CRIT=3
SEVERITY=${SEV_OK}

SUMMARY=()
DETAILS=()
PERFDATA=()

TMP_OUT=""
TMP_ERR=""
trap 'rm -f -- "$TMP_OUT" "$TMP_ERR" 2>/dev/null || true' EXIT

usage() {
    cat <<EOF
Usage: ${PLUGIN_NAME} -p <directory> --pattern <glob> [--sidecar-ext <ext>]
                      [--min-age-seconds <n>] [-t <seconds>] [-V] [-h]

Verifies the newest archive matching a glob: that it decompresses cleanly, and
that its checksum sidecar is present.

Options:
  -p, --path             Directory to look in (not recursive)        [required]
      --pattern          Filename glob, e.g. 'itop-db-*.sql.gz'      [required]
                         A basename pattern - it must not contain '/'.
      --sidecar-ext      Checksum sidecar suffix, appended to the archive name
                         (default: ${SIDECAR_EXT}). Use '' to skip the check.
      --min-age-seconds  Never test an archive younger than this, because it may
                         still be being written (default: ${MIN_AGE_SECONDS})
  -t, --timeout          Timeout for the decompression test (default: ${TIMEOUT}).
                         Deliberately longer than the repo-wide default of 30:
                         this reads the whole archive.
  -V, --version          Show version
  -h, --help             Show this help

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

exit_critical() {
    echo "${PLUGIN_NAME} CRITICAL - $1"
    exit "${STATE_CRITICAL}"
}

check_dependencies() {
    for cmd in find timeout basename; do
        command -v "${cmd}" >/dev/null 2>&1 || \
            exit_unknown "Required command not found: ${cmd}"
    done
}

# decompress_cmd PATH -> echoes the test command, or nothing if unsupported.
decompress_cmd() {
    case "$1" in
        *.tar.gz|*.tgz)   echo "tar -tzf" ;;
        *.tar.bz2|*.tbz2) echo "tar -tjf" ;;
        *.tar.xz|*.txz)   echo "tar -tJf" ;;
        *.gz)             echo "gzip -t"  ;;
        *.bz2)            echo "bzip2 -t" ;;
        *.xz)             echo "xz -t"    ;;
        *.zip)            echo "unzip -t" ;;
        *)                echo ""         ;;
    esac
}

main() {
    # --- Pre-flight -------------------------------------------------------
    if [[ ! -e "$DIR" ]]; then
        exit_critical "directory ${DIR} does not exist - there is nothing to verify"
    elif [[ ! -d "$DIR" ]]; then
        exit_unknown "${DIR} is not a directory"
    elif [[ ! -r "$DIR" || ! -x "$DIR" ]]; then
        exit_unknown "${DIR} is not readable by $(id -un) - cannot verify anything"
    fi

    # --- Enumerate --------------------------------------------------------
    TMP_OUT=$(mktemp) || exit_unknown "cannot create temporary file"
    TMP_ERR=$(mktemp) || exit_unknown "cannot create temporary file"

    local rc=0
    timeout --kill-after=2 "${TIMEOUT}" \
        find -L "$DIR" -maxdepth 1 -type f -name "$PATTERN" -printf '%T@ %s %p\0' \
        >"$TMP_OUT" 2>"$TMP_ERR" || rc=$?

    if [[ $rc -eq 124 || $rc -eq 137 ]]; then
        exit_unknown "scanning ${DIR} timed out after ${TIMEOUT}s"
    fi
    if [[ $rc -ne 0 || -s "$TMP_ERR" ]]; then
        exit_unknown "scanning ${DIR} failed (rc=${rc}): $(head -n1 "$TMP_ERR")"
    fi

    # --- Choose what to test ----------------------------------------------
    # Two candidates are tracked: the newest match overall, and the newest that
    # is old enough to be safe to read. When they differ, the newest is still
    # being written and the older one is tested instead.
    local now; now=$(date +%s)
    local newest_mtime=0 newest_path=""
    local cand_mtime=0 cand_path="" cand_size=0
    local match_count=0
    local rec ts rest size path age

    while IFS= read -r -d '' rec; do
        ts=${rec%% *}
        rest=${rec#* }
        size=${rest%% *}
        path=${rest#* }
        ts=${ts%%.*}
        is_number "$ts" || continue
        is_number "$size" || continue
        match_count=$(( match_count + 1 ))

        if (( ts > newest_mtime )); then
            newest_mtime=$ts
            newest_path=$path
        fi

        age=$(( now - ts ))
        (( age < 0 )) && age=0
        if (( age >= MIN_AGE_SECONDS )) && (( ts > cand_mtime )); then
            cand_mtime=$ts
            cand_path=$path
            cand_size=$size
        fi
    done <"$TMP_OUT"

    if (( match_count == 0 )); then
        exit_critical "no file matching '${PATTERN}' in ${DIR} - there is nothing to verify"
    fi

    local skipped_note=""
    if [[ -z "$cand_path" ]]; then
        # Everything that matched is younger than --min-age-seconds. Reading any
        # of it risks a false CRITICAL against a half-written file, so report OK
        # and say plainly that nothing was verified.
        local newest_age=$(( now - newest_mtime ))
        (( newest_age < 0 )) && newest_age=0
        echo "${PLUGIN_NAME} OK - nothing old enough to test; newest $(basename "$newest_path") is ${newest_age}s old (min-age ${MIN_AGE_SECONDS}s), likely still being written | tested_age_seconds=U integrity_ok=U sidecar_present=U"
        exit "${STATE_OK}"
    fi
    if [[ "$cand_path" != "$newest_path" ]]; then
        local newest_age=$(( now - newest_mtime ))
        (( newest_age < 0 )) && newest_age=0
        skipped_note=" (newest $(basename "$newest_path") is only ${newest_age}s old and may still be being written)"
    fi

    local name tested_age
    name=$(basename "$cand_path")
    tested_age=$(( now - cand_mtime ))
    (( tested_age < 0 )) && tested_age=0

    PERFDATA+=("archive_bytes=${cand_size}B")
    PERFDATA+=("tested_age_seconds=${tested_age}s")

    # --- Sub-check 1: the archive decompresses ----------------------------
    if [[ ! -r "$cand_path" ]]; then
        record "${SEV_UNKNOWN}" "integrity" "${name} is not readable by $(id -un)"
        PERFDATA+=("integrity_ok=U")
    else
        local cmd
        cmd=$(decompress_cmd "$cand_path")
        if [[ -z "$cmd" ]]; then
            record "${SEV_UNKNOWN}" "integrity" "${name} has no known decompression test"
            PERFDATA+=("integrity_ok=U")
        else
            local trc=0 tout=""
            # shellcheck disable=SC2086
            # $cmd is built by decompress_cmd from a fixed list above, never from
            # user input, and must word-split into command plus flags.
            tout=$(timeout --kill-after=2 "${TIMEOUT}" $cmd "$cand_path" 2>&1) || trc=$?
            if [[ $trc -eq 124 || $trc -eq 137 ]]; then
                record "${SEV_UNKNOWN}" "integrity" "decompression test of ${name} timed out after ${TIMEOUT}s"
                PERFDATA+=("integrity_ok=U")
            elif [[ $trc -ne 0 ]]; then
                record "${SEV_CRIT}" "integrity" "${name} failed the decompression test: ${tout:-rc=$trc}"
                PERFDATA+=("integrity_ok=0")
            else
                record "${SEV_OK}" "integrity" "${name} decompresses cleanly (${cand_size} bytes, ${tested_age}s old)"
                PERFDATA+=("integrity_ok=1")
            fi
        fi
    fi

    # --- Sub-check 2: the checksum sidecar is present ---------------------
    if [[ -z "$SIDECAR_EXT" ]]; then
        PERFDATA+=("sidecar_present=U")
    else
        local sidecar="${cand_path}${SIDECAR_EXT}"
        if [[ -f "$sidecar" ]]; then
            if [[ -s "$sidecar" ]]; then
                record "${SEV_OK}" "sidecar" "$(basename "$sidecar") present"
                PERFDATA+=("sidecar_present=1")
            else
                record "${SEV_WARN}" "sidecar" "$(basename "$sidecar") is empty"
                PERFDATA+=("sidecar_present=0")
            fi
        else
            # The archive itself may be perfectly good - this says the job did
            # not reach its final step, which is a script regression, not a
            # missing backup. Hence WARNING rather than CRITICAL.
            record "${SEV_WARN}" "sidecar" "no ${SIDECAR_EXT} sidecar beside ${name}"
            PERFDATA+=("sidecar_present=0")
        fi
    fi

    # --- Output -----------------------------------------------------------
    local label exit_code
    case ${SEVERITY} in
        "${SEV_OK}")   label="OK";       exit_code=${STATE_OK}       ;;
        "${SEV_WARN}") label="WARNING";  exit_code=${STATE_WARNING}  ;;
        "${SEV_CRIT}") label="CRITICAL"; exit_code=${STATE_CRITICAL} ;;
        *)             label="UNKNOWN";  exit_code=${STATE_UNKNOWN}  ;;
    esac

    # The age of the file actually tested is stated up front, so a green
    # integrity check is never misread as a green backup - this plugin will
    # happily pass on a three-year-old archive.
    local out="${PLUGIN_NAME} ${label} - tested ${name} (${tested_age}s old): ${SUMMARY[*]}${skipped_note}"
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
        -p|--path)          DIR="${2:-}";             shift 2 ;;
        --pattern)          PATTERN="${2:-}";         shift 2 ;;
        --sidecar-ext)      SIDECAR_EXT="${2:-}";     shift 2 ;;
        --min-age-seconds)  MIN_AGE_SECONDS="${2:-}"; shift 2 ;;
        -t|--timeout)       TIMEOUT="${2:-}";         shift 2 ;;
        -V|--version)       echo "${PLUGIN_NAME} v${PLUGIN_VERSION}"; exit "${STATE_OK}" ;;
        -h|--help)          usage ;;
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

for v in MIN_AGE_SECONDS TIMEOUT; do
    is_number "${!v}" || exit_unknown "${v} must be a non-negative integer"
done

check_dependencies
main
