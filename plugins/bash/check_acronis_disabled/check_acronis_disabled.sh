#!/usr/bin/env bash
# MIT License
# Copyright (c) 2025 ISW Kudos
# https://github.com/isw-kudos/icinga-plugins/blob/main/LICENSE
#
# check_acronis_disabled - Icinga/Nagios plugin (safety net, WARNING-only)
#
# Verifies that two Acronis Cyber Protect (IONOS Cloud Backup) components stay
# DISABLED on headless AlmaLinux 9 servers, where our Ansible role deliberately
# turns them off. A cloud-side "pull", an agent update, or a manual change could
# silently re-enable them; this check tells us when that happens. It is READ-ONLY
# and NEVER stops/starts/disables anything.
#
# Because a re-enabled component is a policy drift and not a service outage, this
# plugin returns WARNING (never CRITICAL) when a component is back.
#
# Components and their required ("good") state:
#   1. cyber-protect-service - active-protection / antimalware daemon (systemd).
#        Good: NOT running AND NOT enabled at boot.
#          systemctl is-active  <svc> -> expect inactive/failed  (WARN if active)
#          systemctl is-enabled <svc> -> expect disabled/masked  (WARN if enabled)
#   2. cyber-desktop-service - Cyber Protect Connect / desktop "tray". This is NOT
#        a systemd service: it is a unit launched and supervised by the Acronis
#        agent core (aakore), so it is inspected through aakore, not systemd.
#        Good: managed unit DISABLED and its process NOT running.
#          pgrep -f <tray-bin>  -> expect no match             (WARN if running)
#          aakore units         -> local row STAT expected to start with '-'.
#                                  STAT '+...' = enabled (WARN). The cloud-
#                                  registration reference row has STAT exactly
#                                  '+X' and MUST be ignored.
#
# aakore units needs root - see INSTALL.md (run the plugin via sudo or as root).
#
# Worst-state precedence here is OK < UNKNOWN < WARNING: a confirmed re-enabled
# component (WARNING) is the actionable signal and must not be masked by an
# indeterminate sub-result (UNKNOWN). The plugin never emits CRITICAL.
#
# Exit codes: 0=OK, 1=WARNING, 3=UNKNOWN  (2=CRITICAL is never emitted)
#

set -euo pipefail

PLUGIN_NAME="check_acronis_disabled"
PLUGIN_VERSION="1.0.1"

# ---------- Defaults (override via flags; the paths match a stock Acronis agent) ----------
SERVICE="cyber-protect-service.service"          # systemd unit for component 1
UNIT="cyber-desktop-service"                      # aakore unit name for component 2
TRAY_BIN="/opt/acronis/bin/cyber-desktop-service-qt6"  # tray binary (matched as argv[0])
AAKORE="/opt/acronis/aakore"                      # Acronis agent core CLI
TIMEOUT=30

# procfs root. Overridable only for testing (the tray detection scans it); a real
# run always uses /proc.
PROC_ROOT="${PROC_ROOT:-/proc}"

STATE_OK=0
STATE_WARNING=1
STATE_UNKNOWN=3
# Note: STATE_CRITICAL (2) is intentionally NOT defined - this plugin never
# emits CRITICAL. A re-enabled component is policy drift, not an outage.

# Internal severity, ordered so WARNING outranks UNKNOWN (see header). Mapped to
# the real exit code at the very end.
SEV_OK=0
SEV_UNKNOWN=1
SEV_WARN=2
SEVERITY=${SEV_OK}

SUMMARY=()   # one human phrase per component -> first output line
DETAILS=()   # [TAG] detail lines -> subsequent output lines
PERFDATA=()

usage() {
    cat <<EOF
Usage: ${PLUGIN_NAME} [options]

Verifies the two deliberately-disabled Acronis Cyber Protect components have not
come back. Read-only. Returns WARNING (never CRITICAL) if either is re-enabled.

Options:
  --service NAME    systemd unit for cyber-protect-service
                    (default: ${SERVICE})
  --unit NAME       aakore unit name for the desktop/tray component
                    (default: ${UNIT})
  --tray-bin PATH   Tray binary matched with 'pgrep -f'
                    (default: ${TRAY_BIN})
  --aakore PATH     Path to the Acronis agent core CLI
                    (default: ${AAKORE})
  -t SECONDS        Timeout per external command (default: ${TIMEOUT})
  -V, --version     Show version
  -h, --help        Show this help

Exit codes: 0=OK, 1=WARNING, 3=UNKNOWN  (CRITICAL is never emitted)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --service)  SERVICE="$2";  shift 2 ;;
        --unit)     UNIT="$2";     shift 2 ;;
        --tray-bin) TRAY_BIN="$2"; shift 2 ;;
        --aakore)   AAKORE="$2";   shift 2 ;;
        -t)         TIMEOUT="$2";  shift 2 ;;
        -V|--version) echo "${PLUGIN_NAME} v${PLUGIN_VERSION}"; exit "${STATE_OK}" ;;
        -h|--help)    usage; exit "${STATE_UNKNOWN}" ;;
        *) echo "${PLUGIN_NAME} UNKNOWN - Unrecognized option: $1"; exit "${STATE_UNKNOWN}" ;;
    esac
done

escalate() {
    local s=$1
    if (( s > SEVERITY )); then SEVERITY=$s; fi
}

# record <severity> <detail>
record() {
    local sev=$1 detail=$2 tag
    case $sev in
        "${SEV_OK}")      tag="OK"      ;;
        "${SEV_WARN}")    tag="WARN"    ;;
        "${SEV_UNKNOWN}") tag="UNKNOWN" ;;
        *)                tag="UNKNOWN" ;;
    esac
    DETAILS+=("[$tag] $detail")
    escalate "$sev"
}

# run <cmd...> : run with a timeout, capturing combined output in RUN_OUT and the
# exit code in RUN_RC. Never trips set -e; callers decide what a non-zero rc means
# (many of the commands here - is-enabled, pgrep - use rc as data, not as error).
RUN_OUT=""
RUN_RC=0
run() {
    RUN_OUT=""
    RUN_RC=0
    RUN_OUT=$(timeout --kill-after=2 "$TIMEOUT" "$@" 2>&1) || RUN_RC=$?
    return 0
}

timed_out() { [[ "$1" -eq 124 || "$1" -eq 137 ]]; }

# find_tray_pids : locate the REAL tray process(es). Sets TRAY_PIDS (space-
# separated pids, empty if none).
#
# We identify the tray by its argv[0] (the executable it was launched as), read
# from /proc/<pid>/cmdline, NOT by "the tray path appears somewhere in the command
# line". That distinction matters: Icinga passes the tray path to this plugin via
# --tray-bin, and the plugin in turn passes it to its own helpers, so the string
# appears in the command line of the check script, a bash subshell, sudo, timeout
# and pgrep. Any of those is a false "tray running" match. argv[0] of every one of
# those is bash/sudo/timeout/pgrep - never the tray binary - so an argv[0] test
# cannot self-match, regardless of process group (timeout/sudo relocate their
# PGID, which is why a process-group filter is not enough). /proc/<pid>/cmdline is
# world-readable, so this needs no root. See the CHANGELOG for the fixed bug.
TRAY_PIDS=""
find_tray_pids() {
    TRAY_PIDS=""
    local base entry pid argv0 pids=()
    base=${TRAY_BIN##*/}
    for entry in "$PROC_ROOT"/[0-9]*; do
        [[ -d "$entry" ]] || continue          # no glob match -> literal path, skip
        pid=${entry##*/}
        argv0=""
        argv0=$(tr '\0' '\n' < "$entry/cmdline" 2>/dev/null | head -n1) || true
        [[ -z "$argv0" ]] && continue          # kernel threads / exited procs
        # Match the tray whether launched by full path or by bare name.
        if [[ "$argv0" == "$TRAY_BIN" || "${argv0##*/}" == "$base" ]]; then
            pids+=("$pid")
        fi
    done
    if (( ${#pids[@]} )); then TRAY_PIDS="${pids[*]}"; fi
    return 0
}

check_dependencies() {
    for cmd in systemctl awk timeout; do
        command -v "${cmd}" >/dev/null 2>&1 || {
            echo "${PLUGIN_NAME} UNKNOWN - Required command not found: ${cmd}"
            exit "${STATE_UNKNOWN}"
        }
    done
}

# ---------------------------------------------------------------------------
# Presence detection (drives the "agent not installed" short-circuit)
# ---------------------------------------------------------------------------
PROTECT_PRESENT=0     # is the cyber-protect-service unit known to systemd?
AAKORE_PRESENT=0      # is the aakore CLI installed?

ACTIVE_STATE=""
ENABLED_STATE=""

detect_protect_presence() {
    # is-enabled reports the unit-file state; for an unknown unit it prints
    # "not-found" (systemd >= 248) or ".../No such file or directory" (older) and
    # exits non-zero. is-active for an unknown unit prints "inactive". We parse
    # output, not rc, since "disabled" also exits non-zero by design.
    run systemctl is-active "$SERVICE"
    if timed_out "$RUN_RC"; then ACTIVE_STATE="__timeout__"; fi
    ACTIVE_STATE=${ACTIVE_STATE:-$(printf '%s' "$RUN_OUT" | head -n1 | tr -d '[:space:]')}

    run systemctl is-enabled "$SERVICE"
    if timed_out "$RUN_RC"; then ENABLED_STATE="__timeout__"; fi
    local out; out=$(printf '%s' "$RUN_OUT" | head -n1 | tr -d '[:space:]')
    ENABLED_STATE=${ENABLED_STATE:-$out}

    if [[ "$RUN_OUT" == *"not-found"* || "$RUN_OUT" == *"No such file"* ]]; then
        PROTECT_PRESENT=0
    else
        PROTECT_PRESENT=1
    fi
}

detect_aakore_presence() {
    [[ -x "$AAKORE" ]] && AAKORE_PRESENT=1 || AAKORE_PRESENT=0
}

# ---------------------------------------------------------------------------
# Component 1 - cyber-protect-service (systemd)
# ---------------------------------------------------------------------------
check_protect_service() {
    if [[ "$ACTIVE_STATE" == "__timeout__" || "$ENABLED_STATE" == "__timeout__" ]]; then
        record "${SEV_UNKNOWN}" "cyber-protect-service: systemctl timed out after ${TIMEOUT}s"
        SUMMARY+=("cyber-protect-service state unknown (systemctl timeout)")
        return
    fi

    local active_bad=0 enabled_bad=0
    # "active", "activating" and "reloading" all mean the daemon is up.
    case "$ACTIVE_STATE" in active|activating|reloading) active_bad=1 ;; esac
    # "enabled"/"enabled-runtime" mean it starts at boot. "disabled", "masked",
    # "static", "indirect" are all acceptable (not auto-started).
    [[ "$ENABLED_STATE" == enabled* ]] && enabled_bad=1

    PERFDATA+=("cyber_protect_active=${active_bad};1;;0;1")
    PERFDATA+=("cyber_protect_enabled=${enabled_bad};1;;0;1")

    if (( active_bad || enabled_bad )); then
        record "${SEV_WARN}" "cyber-protect-service is ${ACTIVE_STATE}/${ENABLED_STATE} (expected inactive/disabled) - it has been re-enabled"
        SUMMARY+=("cyber-protect-service ${ACTIVE_STATE}/${ENABLED_STATE}")
    else
        record "${SEV_OK}" "cyber-protect-service ${ACTIVE_STATE}/${ENABLED_STATE}"
        SUMMARY+=("cyber-protect-service ${ACTIVE_STATE}/${ENABLED_STATE}")
    fi
}

# ---------------------------------------------------------------------------
# Component 2 - cyber-desktop-service (aakore-managed unit + process)
# ---------------------------------------------------------------------------
check_desktop_service() {
    # --- Process check (no root needed) ---
    # find_tray_pids matches on argv[0] via /proc, so it identifies the real tray
    # binary and never the plugin's own helpers that carry the path as an argument.
    find_tray_pids
    local tray_running=0 first_pid=""
    if [[ -n "$TRAY_PIDS" ]]; then
        tray_running=1
        first_pid=${TRAY_PIDS%% *}
    fi
    PERFDATA+=("cyber_desktop_tray=${tray_running};1;;0;1")

    # --- Config / enabled-state via aakore (needs root; degrade gracefully) ---
    # We parse only the LOCAL managed row: $1 == unit name, excluding the cloud-
    # registration reference row whose STAT is exactly '+X'. Leading '-' = disabled
    # (good), leading '+' = enabled (bad).
    local cfg_word="" unit_stat="" unit_enabled=-1
    if (( AAKORE_PRESENT )); then
        run "$AAKORE" units
        if timed_out "$RUN_RC"; then
            cfg_word="aakore timed out after ${TIMEOUT}s - unit state unknown"
        elif [[ "$RUN_RC" -ne 0 ]]; then
            # Core down or insufficient privileges: fall back to the process check.
            cfg_word="aakore unit state unavailable (core down or not root)"
        else
            unit_stat=$(printf '%s\n' "$RUN_OUT" \
                | awk -v u="$UNIT" '$1==u && $2 !~ /^\+X/ {print $2; exit}')
            if [[ -z "$unit_stat" ]]; then
                cfg_word="no local ${UNIT} unit registered in aakore"
            elif [[ "$unit_stat" == +* ]]; then
                unit_enabled=1
                cfg_word="aakore unit ENABLED (STAT ${unit_stat})"
            elif [[ "$unit_stat" == -* ]]; then
                unit_enabled=0
                cfg_word="disabled (STAT ${unit_stat})"
            else
                cfg_word="aakore unit STAT '${unit_stat}' unexpected"
            fi
        fi
    else
        cfg_word="aakore not installed"
    fi

    if (( unit_enabled >= 0 )); then
        PERFDATA+=("cyber_desktop_unit_enabled=${unit_enabled};1;;0;1")
    fi

    # --- Combine into a verdict ---
    local tray_word
    if (( tray_running )); then
        tray_word="tray running (pid ${first_pid})"
    else
        tray_word="tray not running"
    fi

    local bad=0
    (( tray_running )) && bad=1
    (( unit_enabled == 1 )) && bad=1

    local phrase="cyber-desktop-service ${cfg_word}, ${tray_word}"
    SUMMARY+=("$phrase")
    if (( bad )); then
        record "${SEV_WARN}" "${phrase} - it has been re-enabled"
    else
        record "${SEV_OK}" "${phrase}"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
check_dependencies
detect_protect_presence
detect_aakore_presence

# Safe to apply broadly: if neither component is present, there is nothing to
# check. Report OK so hosts without the agent do not alert.
if (( ! PROTECT_PRESENT && ! AAKORE_PRESENT )); then
    echo "${PLUGIN_NAME} OK - Acronis agent not installed - nothing to check"
    exit "${STATE_OK}"
fi

if (( PROTECT_PRESENT )); then
    check_protect_service
else
    SUMMARY+=("cyber-protect-service not installed")
    record "${SEV_OK}" "cyber-protect-service unit not present on this host"
fi

check_desktop_service

case $SEVERITY in
    "${SEV_OK}")      LABEL="OK";      CODE=${STATE_OK}      ;;
    "${SEV_WARN}")    LABEL="WARNING"; CODE=${STATE_WARNING} ;;
    "${SEV_UNKNOWN}") LABEL="UNKNOWN"; CODE=${STATE_UNKNOWN} ;;
    *)                LABEL="UNKNOWN"; CODE=${STATE_UNKNOWN} ;;
esac

# Join the per-component summary phrases with "; ".
joined=""
for i in "${!SUMMARY[@]}"; do
    if (( i == 0 )); then joined="${SUMMARY[$i]}"; else joined="${joined}; ${SUMMARY[$i]}"; fi
done

if [[ ${#PERFDATA[@]} -gt 0 ]]; then
    echo "${PLUGIN_NAME} ${LABEL} - ${joined} | ${PERFDATA[*]}"
else
    echo "${PLUGIN_NAME} ${LABEL} - ${joined}"
fi
for d in "${DETAILS[@]}"; do echo "$d"; done

exit "${CODE}"
