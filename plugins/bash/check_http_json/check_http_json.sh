#!/usr/bin/env bash
# MIT License
# Copyright (c) 2025 ISW Kudos
# https://github.com/isw-kudos/icinga-plugins/blob/main/LICENSE

set -euo pipefail

PLUGIN_NAME="check_http_json"
PLUGIN_VERSION="1.1.0"
TIMEOUT=30

# --- Defaults ---
URL=""
INSECURE=0
EXPECTS=()
HEADERS=()

# --- Exit Codes ---
# This plugin only ever returns OK / CRITICAL / UNKNOWN (no WARNING state).
STATE_OK=0
STATE_CRITICAL=2
STATE_UNKNOWN=3

# --- Functions ---
usage() {
  cat <<EOF
Usage: ${PLUGIN_NAME} -U <url> --expect '<jq-path>=<value>' [--expect ...]
                      [--header '<name>: <value>' ...] [-k] [-t <timeout>] [-V] [-h]

Fetches a URL over HTTP(S), parses the JSON response, and verifies that one or
more fields match expected values. Any mismatch, non-2xx status, connection
failure, or unparseable body results in CRITICAL.

Options:
  -U, --url        Target URL (e.g. https://host/route.id)          [required]
      --expect     Field check '<jq-path>=<expected>', e.g. '.route=lhss'.
                   Repeatable; at least one is required.
      --header     Custom request header, e.g. 'host: social.example.com'.
                   Repeatable.
  -k, --insecure   Skip TLS certificate verification (default: verify)
  -t, --timeout    Timeout in seconds (default: ${TIMEOUT})
  -V, --version    Show version
  -h, --help       Show this help
EOF
  exit "${STATE_UNKNOWN}"
}

check_dependencies() {
  for cmd in curl jq; do
    command -v "${cmd}" >/dev/null 2>&1 || {
      echo "${PLUGIN_NAME} UNKNOWN - Required command not found: ${cmd}"
      exit "${STATE_UNKNOWN}"
    }
  done
}

main() {
  if ! [[ "${TIMEOUT}" =~ ^[0-9]+$ ]] || [[ "${TIMEOUT}" -eq 0 ]]; then
    echo "${PLUGIN_NAME} UNKNOWN - Timeout (-t) must be a positive integer"
    exit "${STATE_UNKNOWN}"
  fi

  local body_tmp
  body_tmp="$(mktemp)"
  trap 'rm -f "${body_tmp}"' EXIT

  # --- Build curl argument array (never eval) ---
  local curl_args=(
    --silent
    --show-error
    --connect-timeout "${TIMEOUT}"
    --max-time "${TIMEOUT}"
    --output "${body_tmp}"
    --write-out '%{http_code} %{time_total}'
  )
  (( INSECURE )) && curl_args+=(--insecure)

  local hdr
  if [[ "${#HEADERS[@]}" -gt 0 ]]; then
    for hdr in "${HEADERS[@]}"; do
      curl_args+=(--header "${hdr}")
    done
  fi

  curl_args+=("${URL}")

  # --- Execute request ---
  # curl already bounds the request via --connect-timeout/--max-time; wrap in
  # `timeout` as a belt-and-suspenders guard only when it is available.
  local cmd=()
  if command -v timeout >/dev/null 2>&1; then
    cmd=(timeout --kill-after=2 "${TIMEOUT}")
  fi
  cmd+=(curl "${curl_args[@]}")

  local write_out curl_exit=0
  write_out="$("${cmd[@]}" 2>/dev/null)" || curl_exit=$?

  if [[ "${curl_exit}" -ne 0 ]]; then
    case "${curl_exit}" in
      6)   echo "${PLUGIN_NAME} CRITICAL - Could not resolve host for ${URL}"; exit "${STATE_CRITICAL}" ;;
      7)   echo "${PLUGIN_NAME} CRITICAL - Failed to connect to ${URL}"; exit "${STATE_CRITICAL}" ;;
      28)  echo "${PLUGIN_NAME} UNKNOWN - Plugin timed out after ${TIMEOUT} seconds"; exit "${STATE_UNKNOWN}" ;;
      124) echo "${PLUGIN_NAME} UNKNOWN - Plugin timed out after ${TIMEOUT} seconds"; exit "${STATE_UNKNOWN}" ;;
      *)   echo "${PLUGIN_NAME} UNKNOWN - curl error ${curl_exit} requesting ${URL}"; exit "${STATE_UNKNOWN}" ;;
    esac
  fi

  local http_code time_total
  http_code="${write_out%% *}"
  time_total="${write_out##* }"

  local perfdata="time=${time_total}s;;;0 checks=${#EXPECTS[@]}"

  # --- HTTP status must be 2xx ---
  if ! [[ "${http_code}" =~ ^2[0-9][0-9]$ ]]; then
    echo "${PLUGIN_NAME} CRITICAL - HTTP ${http_code} from ${URL} | ${perfdata}"
    exit "${STATE_CRITICAL}"
  fi

  # --- Body must be valid JSON ---
  if ! jq -e . "${body_tmp}" >/dev/null 2>&1; then
    echo "${PLUGIN_NAME} CRITICAL - Response body is not valid JSON | ${perfdata}"
    exit "${STATE_CRITICAL}"
  fi

  # --- Field checks ---
  local ok_details=() fail_details=() spec path jq_path expected actual jq_err
  for spec in "${EXPECTS[@]}"; do
    if [[ "${spec}" != *"="* ]]; then
      echo "${PLUGIN_NAME} UNKNOWN - Invalid --expect '${spec}' (expected '<jq-path>=<value>')"
      exit "${STATE_UNKNOWN}"
    fi
    path="${spec%%=*}"
    expected="${spec#*=}"

    # Convenience: accept a bare key path ('route', 'data.route') by prefixing
    # the jq '.'; anything already starting with '.', '[' or '(' is passed as-is.
    case "${path}" in
      .*|\[*|\(*) jq_path="${path}" ;;
      *)          jq_path=".${path}" ;;
    esac

    # A filter that fails to compile is an operator error, not a check failure.
    if jq_err="$(jq -n "${jq_path}" 2>&1 >/dev/null)"; [[ -n "${jq_err}" ]]; then
      echo "${PLUGIN_NAME} UNKNOWN - Invalid jq path '${path}': ${jq_err##*jq: error: }"
      exit "${STATE_UNKNOWN}"
    fi

    if ! actual="$(jq -er "${jq_path}" "${body_tmp}" 2>/dev/null)"; then
      fail_details+=("${path} missing or null")
      continue
    fi

    if [[ "${actual}" == "${expected}" ]]; then
      ok_details+=("${path}=${actual}")
    else
      fail_details+=("${path} expected=${expected} got=${actual}")
    fi
  done

  if [[ "${#fail_details[@]}" -gt 0 ]]; then
    local summary
    printf -v summary '%s; ' "${fail_details[@]}"
    echo "${PLUGIN_NAME} CRITICAL - ${summary%; } | ${perfdata}"
    printf '%s\n' "${fail_details[@]}"
    exit "${STATE_CRITICAL}"
  fi

  local summary
  printf -v summary '%s, ' "${ok_details[@]}"
  echo "${PLUGIN_NAME} OK - ${#ok_details[@]} field(s) matched: ${summary%, } | ${perfdata}"
  exit "${STATE_OK}"
}

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -U|--url)      URL="$2"; shift 2 ;;
    --expect)      EXPECTS+=("$2"); shift 2 ;;
    --header)      HEADERS+=("$2"); shift 2 ;;
    -k|--insecure) INSECURE=1; shift ;;
    -t|--timeout)  TIMEOUT="$2"; shift 2 ;;
    -V|--version)  echo "${PLUGIN_NAME} v${PLUGIN_VERSION}"; exit "${STATE_OK}" ;;
    -h|--help)     usage ;;
    *)             echo "${PLUGIN_NAME} UNKNOWN - Unrecognized option: $1"; exit "${STATE_UNKNOWN}" ;;
  esac
done

if [[ -z "${URL}" ]]; then
  echo "${PLUGIN_NAME} UNKNOWN - URL (-U) is required"
  exit "${STATE_UNKNOWN}"
fi

if [[ "${#EXPECTS[@]}" -eq 0 ]]; then
  echo "${PLUGIN_NAME} UNKNOWN - At least one --expect '<jq-path>=<value>' is required"
  exit "${STATE_UNKNOWN}"
fi

check_dependencies
main
