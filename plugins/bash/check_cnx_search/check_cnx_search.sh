#!/usr/bin/env bash
# MIT License
# Copyright (c) 2025 ISW Kudos
# https://github.com/isw-kudos/icinga-plugins/blob/main/LICENSE

set -euo pipefail

PLUGIN_NAME="check_cnx_search"
PLUGIN_VERSION="1.0.0"
TIMEOUT=30

# --- Defaults ---
WARNING_HOURS=20
CRITICAL_HOURS=24
USERNAME=""
PASSWORD=""
BASE_URL=""

# --- Exit Codes ---
STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3

# --- Functions ---
usage() {
  cat <<EOF
Usage: ${PLUGIN_NAME} -H <url> -u <username> -p <password> [-w <warning_hours>] [-c <critical_hours>] [-t <timeout>] [-V] [-h]

Options:
  -H  HCL Connections base URL (e.g. https://connections.example.com)
  -u  Username for authentication
  -p  Password for authentication
  -w  Warning threshold in hours (default: ${WARNING_HOURS})
  -c  Critical threshold in hours (default: ${CRITICAL_HOURS})
  -t  Timeout in seconds (default: ${TIMEOUT})
  -V  Show version
  -h  Show this help
EOF
  exit "${STATE_UNKNOWN}"
}

check_dependencies() {
  for cmd in curl xmllint date; do
    command -v "${cmd}" >/dev/null 2>&1 || {
      echo "${PLUGIN_NAME} UNKNOWN - Required command not found: ${cmd}"
      exit "${STATE_UNKNOWN}"
    }
  done
}

main() {
  if [[ "${WARNING_HOURS}" -ge "${CRITICAL_HOURS}" ]]; then
    echo "${PLUGIN_NAME} UNKNOWN - Warning threshold (${WARNING_HOURS}h) must be less than Critical threshold (${CRITICAL_HOURS}h)"
    exit "${STATE_UNKNOWN}"
  fi

  local warning_seconds critical_seconds
  warning_seconds=$(( WARNING_HOURS * 3600 ))
  critical_seconds=$(( CRITICAL_HOURS * 3600 ))

  local tmp_file
  tmp_file=$(mktemp /tmp/cnx-search-XXXXXX.xml)
  trap 'rm -f "${tmp_file}"' EXIT

  local curl_exit=0
  curl --insecure \
    --silent \
    --user "${USERNAME}:${PASSWORD}" \
    --header "Accept: application/atom+xml" \
    --max-time "${TIMEOUT}" \
    --fail \
    --output "${tmp_file}" \
    "${BASE_URL}/search/atom/search?query=test" || curl_exit=$?

  if [[ "${curl_exit}" -ne 0 ]]; then
    if [[ "${curl_exit}" -eq 28 ]]; then
      echo "${PLUGIN_NAME} UNKNOWN - Plugin timed out after ${TIMEOUT} seconds"
      exit "${STATE_UNKNOWN}"
    fi
    echo "${PLUGIN_NAME} CRITICAL - curl request failed (exit ${curl_exit}) - could not reach ${BASE_URL}"
    exit "${STATE_CRITICAL}"
  fi

  local updated
  updated=$(xmllint --xpath "string(/*[local-name()='feed']/*[local-name()='updated'][1])" "${tmp_file}" 2>/dev/null)

  if [[ -z "${updated}" ]]; then
    echo "${PLUGIN_NAME} UNKNOWN - Could not parse updated timestamp from XML response"
    exit "${STATE_UNKNOWN}"
  fi

  local updated_epoch
  if ! updated_epoch=$(date -d "${updated}" +%s 2>/dev/null); then
    echo "${PLUGIN_NAME} UNKNOWN - Could not convert timestamp '${updated}' to epoch"
    exit "${STATE_UNKNOWN}"
  fi

  local now_epoch age_seconds age_hours age_minutes
  now_epoch=$(date +%s)
  age_seconds=$(( now_epoch - updated_epoch ))
  age_hours=$(( age_seconds / 3600 ))
  age_minutes=$(( (age_seconds % 3600) / 60 ))

  local perfdata="age=${age_seconds}s;${warning_seconds};${critical_seconds};0"

  if (( age_seconds >= critical_seconds )); then
    echo "${PLUGIN_NAME} CRITICAL - Search index is STALE - last updated ${age_hours}h ${age_minutes}m ago | ${perfdata}"
    exit "${STATE_CRITICAL}"
  elif (( age_seconds >= warning_seconds )); then
    echo "${PLUGIN_NAME} WARNING - Search index is aging - last updated ${age_hours}h ${age_minutes}m ago | ${perfdata}"
    exit "${STATE_WARNING}"
  else
    echo "${PLUGIN_NAME} OK - Search index is fresh - last updated ${age_hours}h ${age_minutes}m ago | ${perfdata}"
    exit "${STATE_OK}"
  fi
}

# --- Argument Parsing ---
while getopts ":H:u:p:w:c:t:Vh" opt; do
  case $opt in
    H) BASE_URL="$OPTARG" ;;
    u) USERNAME="$OPTARG" ;;
    p) PASSWORD="$OPTARG" ;;
    w) WARNING_HOURS="$OPTARG" ;;
    c) CRITICAL_HOURS="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
    V) echo "${PLUGIN_NAME} v${PLUGIN_VERSION}"; exit "${STATE_OK}" ;;
    h) usage ;;
    :) echo "${PLUGIN_NAME} UNKNOWN - Option -${OPTARG} requires an argument"; exit "${STATE_UNKNOWN}" ;;
    *) usage ;;
  esac
done

if [[ -z "${BASE_URL}" ]] || [[ -z "${USERNAME}" ]] || [[ -z "${PASSWORD}" ]]; then
  echo "${PLUGIN_NAME} UNKNOWN - Options -H, -u, and -p are required"
  exit "${STATE_UNKNOWN}"
fi

check_dependencies
main
