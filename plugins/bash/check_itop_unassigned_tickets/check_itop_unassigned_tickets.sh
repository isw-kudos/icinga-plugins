#!/usr/bin/env bash
# MIT License
# Copyright (c) 2025 ISW Kudos
# https://github.com/isw-kudos/icinga-plugins/blob/main/LICENSE

set -euo pipefail

PLUGIN_NAME="check_itop_unassigned_tickets"
PLUGIN_VERSION="1.0.0"
TIMEOUT=10

# --- Defaults ---
WARNING_THRESHOLD=1
CRITICAL_THRESHOLD=2
ITOP_URL=""
ITOP_USER=""
ITOP_PASS=""
TICKET_CLASS="Incident"

# --- Exit Codes ---
STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3

# --- Functions ---
usage() {
  cat <<EOF
Usage: ${PLUGIN_NAME} -H <url> -u <username> -p <password> [-w <warning>] [-c <critical>] [-C <class>] [-t <timeout>] [-V] [-h]

Options:
  -H  iTop base URL (e.g. https://itop.example.com)
  -u  iTop API username
  -p  iTop API password
  -w  Warning threshold in unassigned ticket count (default: ${WARNING_THRESHOLD})
  -c  Critical threshold in unassigned ticket count (default: ${CRITICAL_THRESHOLD})
  -C  Ticket class to check (default: ${TICKET_CLASS})
      Supported: Incident, UserRequest, Change, Problem (or any custom class)
  -t  Timeout in seconds (default: ${TIMEOUT})
  -V  Show version
  -h  Show this help
EOF
  exit "${STATE_UNKNOWN}"
}

check_dependencies() {
  for cmd in curl python3; do
    command -v "${cmd}" >/dev/null 2>&1 || {
      echo "${PLUGIN_NAME} UNKNOWN - Required command not found: ${cmd}"
      exit "${STATE_UNKNOWN}"
    }
  done
}

main() {
  if ! [[ "${WARNING_THRESHOLD}" =~ ^[0-9]+$ ]] || ! [[ "${CRITICAL_THRESHOLD}" =~ ^[0-9]+$ ]]; then
    echo "${PLUGIN_NAME} UNKNOWN - Thresholds must be non-negative integers"
    exit "${STATE_UNKNOWN}"
  fi

  if [[ "${WARNING_THRESHOLD}" -ge "${CRITICAL_THRESHOLD}" ]]; then
    echo "${PLUGIN_NAME} UNKNOWN - Warning threshold (${WARNING_THRESHOLD}) must be less than Critical threshold (${CRITICAL_THRESHOLD})"
    exit "${STATE_UNKNOWN}"
  fi

  local oql_query="SELECT ${TICKET_CLASS} WHERE agent_id = 0"
  local json_data
  printf -v json_data \
    '{"operation":"core/get","class":"%s","key":"%s","output_fields":"id,ref,title,status,agent_id"}' \
    "${TICKET_CLASS}" "${oql_query}"

  local api_url="${ITOP_URL}/webservices/rest.php?version=1.3"

  local response curl_exit=0
  response=$(curl \
    --silent \
    --max-time "${TIMEOUT}" \
    --connect-timeout "${TIMEOUT}" \
    --user "${ITOP_USER}:${ITOP_PASS}" \
    --data-urlencode "json_data=${json_data}" \
    "${api_url}" \
    2>/dev/null) || curl_exit=$?

  if [[ "${curl_exit}" -ne 0 ]]; then
    case "${curl_exit}" in
      6)  echo "${PLUGIN_NAME} UNKNOWN - Could not resolve host: ${ITOP_URL}" ;;
      7)  echo "${PLUGIN_NAME} UNKNOWN - Failed to connect to ${ITOP_URL}" ;;
      28) echo "${PLUGIN_NAME} UNKNOWN - Plugin timed out after ${TIMEOUT} seconds" ;;
      *)  echo "${PLUGIN_NAME} UNKNOWN - curl error ${curl_exit}" ;;
    esac
    exit "${STATE_UNKNOWN}"
  fi

  if ! echo "${response}" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    echo "${PLUGIN_NAME} UNKNOWN - Invalid JSON response from iTop API"
    exit "${STATE_UNKNOWN}"
  fi

  local api_code
  api_code=$(echo "${response}" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('code','missing'))" 2>/dev/null)

  if [[ "${api_code}" != "0" ]]; then
    local api_message
    api_message=$(echo "${response}" | python3 -c \
      "import sys,json; d=json.load(sys.stdin); print(d.get('message','Unknown error'))" 2>/dev/null)
    echo "${PLUGIN_NAME} UNKNOWN - iTop API error (code: ${api_code}) - ${api_message}"
    exit "${STATE_UNKNOWN}"
  fi

  local ticket_count
  ticket_count=$(echo "${response}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
objects = data.get('objects', None)
print(0 if objects is None else len(objects))
" 2>/dev/null) || {
    echo "${PLUGIN_NAME} UNKNOWN - Could not parse ticket count from API response"
    exit "${STATE_UNKNOWN}"
  }

  if ! [[ "${ticket_count}" =~ ^[0-9]+$ ]]; then
    echo "${PLUGIN_NAME} UNKNOWN - Could not parse ticket count from API response"
    exit "${STATE_UNKNOWN}"
  fi

  local ticket_details=""
  ticket_details=$(echo "${response}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
objects = data.get('objects', None)
if not objects:
    print('no unassigned tickets')
else:
    tickets = []
    for key, val in objects.items():
        fields = val.get('fields', {})
        ref    = fields.get('ref', 'N/A')
        title  = fields.get('title', 'N/A')
        status = fields.get('status', 'N/A')
        tickets.append(f'{ref} [{status}]: {title}')
    print(', '.join(tickets))
" 2>/dev/null) || true

  local perfdata="unassigned_tickets=${ticket_count};${WARNING_THRESHOLD};${CRITICAL_THRESHOLD};0"

  if [[ "${ticket_count}" -ge "${CRITICAL_THRESHOLD}" ]]; then
    echo "${PLUGIN_NAME} CRITICAL - ${ticket_count} unassigned ${TICKET_CLASS} ticket(s): ${ticket_details} | ${perfdata}"
    exit "${STATE_CRITICAL}"
  elif [[ "${ticket_count}" -ge "${WARNING_THRESHOLD}" ]]; then
    echo "${PLUGIN_NAME} WARNING - ${ticket_count} unassigned ${TICKET_CLASS} ticket(s): ${ticket_details} | ${perfdata}"
    exit "${STATE_WARNING}"
  else
    echo "${PLUGIN_NAME} OK - ${ticket_count} unassigned ${TICKET_CLASS} ticket(s) | ${perfdata}"
    exit "${STATE_OK}"
  fi
}

# --- Argument Parsing ---
while getopts ":H:u:p:w:c:C:t:Vh" opt; do
  case $opt in
    H) ITOP_URL="${OPTARG%/}" ;;
    u) ITOP_USER="$OPTARG" ;;
    p) ITOP_PASS="$OPTARG" ;;
    w) WARNING_THRESHOLD="$OPTARG" ;;
    c) CRITICAL_THRESHOLD="$OPTARG" ;;
    C) TICKET_CLASS="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
    V) echo "${PLUGIN_NAME} v${PLUGIN_VERSION}"; exit "${STATE_OK}" ;;
    h) usage ;;
    :) echo "${PLUGIN_NAME} UNKNOWN - Option -${OPTARG} requires an argument"; exit "${STATE_UNKNOWN}" ;;
    *) usage ;;
  esac
done

if [[ -z "${ITOP_URL}" ]] || [[ -z "${ITOP_USER}" ]] || [[ -z "${ITOP_PASS}" ]]; then
  echo "${PLUGIN_NAME} UNKNOWN - Options -H, -u, and -p are required"
  exit "${STATE_UNKNOWN}"
fi

check_dependencies
main
