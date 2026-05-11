# CLAUDE.md

## Project Overview
This repository contains monitoring plugins for Icinga 2. Plugins are written in
Bash and/or Python. The goal is to provide reliable, well-documented, publicly
accessible plugins following Icinga 2 / Nagios plugin standards.

This project is released under the MIT License.

---

## Repository Structure

plugins/
  bash/
    check_example/
      check_example.sh
      README.md
      INSTALL.md
      CHANGELOG.md
      icinga2/
        checkcommand.conf
        host_template.conf   (if applicable)
        service.conf
  python/
    check_example/
      check_example.py
      README.md
      INSTALL.md
      CHANGELOG.md
      requirements.txt       (if applicable)
      icinga2/
        checkcommand.conf
        host_template.conf   (if applicable)
        service.conf
lib/
  bash/
    common.sh
  python/
    common.py
tests/
  bash/
  python/

---

## License

This project is licensed under the MIT License. The LICENSE file MUST exist in
the repository root.

Every plugin file (.sh or .py) MUST include the following license header:

Bash:
  # MIT License
  # Copyright (c) 2025 ISW Kudos
  # https://github.com/isw-kudos/icinga-plugins/blob/main/LICENSE

Python:
  # MIT License
  # Copyright (c) 2025 ISW Kudos
  # https://github.com/isw-kudos/icinga-plugins/blob/main/LICENSE

---

## Plugin Standards

### Exit Codes (mandatory)
All plugins MUST return the correct exit code:
  0 = OK
  1 = WARNING
  2 = CRITICAL
  3 = UNKNOWN

### Output Format
- First line: PLUGINNAME STATE - Human readable message
- Performance data (if applicable) appended after a pipe |
- Example: CHECK_FOO OK - All 5 widgets healthy | widgets=5;3;1;0;10
- Multi-line output is acceptable; first line is always the summary

### Performance Data
- Format: label=value[UOM];[warn];[crit];[min];[max]
- Always include warn/crit thresholds when applicable
- Use appropriate Unit of Measure (UOM): s, ms, %, B, KB, MB, GB, c

### Timeout Handling
- All plugins MUST respect a -t / --timeout argument
- Default timeout: 30 seconds
- On timeout, exit with code 3 (UNKNOWN):
  CHECK_EXAMPLE UNKNOWN - Plugin timed out after 30 seconds

### Icinga 2 Constants
All plugins and conf files MUST assume Icinga 2 default constants:
  PluginDir        = /usr/lib/nagios/plugins
  PluginContribDir = /usr/lib/nagios/plugins/contrib

Do not hardcode paths. Always use PluginDir in .conf files.

### Minimum Icinga 2 Version
- Each plugin MUST declare its minimum supported Icinga 2 version in README.md and INSTALL.md
- Default minimum unless otherwise stated: Icinga 2 >= 2.13.0

---

## Versioning

All plugins use Semantic Versioning (MAJOR.MINOR.PATCH):

  MAJOR = Breaking change: argument removed/renamed, output format changed
  MINOR = New feature: new argument added, new metric collected
  PATCH = Bug fix, documentation update, refactor with no behaviour change

- Version declared inside plugin script as PLUGIN_VERSION="1.0.0"
- Version included in --version / -V output
- Version MUST be updated in plugin file and per-plugin CHANGELOG.md on every release
- Git tags: pluginname-vMAJOR.MINOR.PATCH e.g. check_example-v1.2.0

---

## Bash Plugin Guidelines

### Requirements
- Target: bash >= 4.x
- Shebang: #!/usr/bin/env bash
- Use set -euo pipefail at the top
- All scripts must be executable (chmod +x)
- Must pass ShellCheck with zero warnings or errors

### Structure Template

#!/usr/bin/env bash
# MIT License
# Copyright (c) 2025 ISW Kudos
# https://github.com/isw-kudos/icinga-plugins/blob/main/LICENSE

set -euo pipefail

PLUGIN_NAME="check_example"
PLUGIN_VERSION="1.0.0"
TIMEOUT=30

# --- Defaults ---
WARNING_THRESHOLD=80
CRITICAL_THRESHOLD=90
HOST=""

# --- Exit Codes ---
STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3

# --- Functions ---
usage() {
  cat <<EOF
Usage: ${PLUGIN_NAME} -H <host> -w <warning> -c <critical> [-t <timeout>] [-V]

Options:
  -H  Target hostname or IP
  -w  Warning threshold
  -c  Critical threshold
  -t  Timeout in seconds (default: ${TIMEOUT})
  -V  Show version
  -h  Show this help
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
  echo "${PLUGIN_NAME} OK - Everything looks good | metric=42;${WARNING_THRESHOLD};${CRITICAL_THRESHOLD};0;100"
  exit "${STATE_OK}"
}

# --- Argument Parsing ---
while getopts ":H:w:c:t:Vh" opt; do
  case $opt in
    H) HOST="$OPTARG" ;;
    w) WARNING_THRESHOLD="$OPTARG" ;;
    c) CRITICAL_THRESHOLD="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
    V) echo "${PLUGIN_NAME} v${PLUGIN_VERSION}"; exit "${STATE_OK}" ;;
    h) usage ;;
    :) echo "${PLUGIN_NAME} UNKNOWN - Option -${OPTARG} requires an argument"; exit "${STATE_UNKNOWN}" ;;
    *) usage ;;
  esac
done

[[ -z "${HOST}" ]] && {
  echo "${PLUGIN_NAME} UNKNOWN - Host (-H) is required"
  exit "${STATE_UNKNOWN}"
}

check_dependencies
main

### Standards
- Always validate required arguments and dependencies
- Use named variables, avoid magic numbers
- Quote all variables: "$VAR"
- Source shared lib: source "$(dirname "$0")/../../lib/bash/common.sh"
- Never use eval
- Never hardcode credentials or paths

---

## Python Plugin Guidelines

### Requirements
- Target: Python >= 3.8
- Shebang: #!/usr/bin/env python3
- Follow PEP 8
- Must pass ruff with zero warnings or errors
- Use argparse for argument handling
- Avoid non-stdlib dependencies where possible; if needed, pin versions in requirements.txt

### Structure Template

#!/usr/bin/env python3
# MIT License
# Copyright (c) 2025 ISW Kudos
# https://github.com/isw-kudos/icinga-plugins/blob/main/LICENSE

"""
check_example - Brief description of what this plugin checks.
"""

import argparse
import sys

PLUGIN_NAME = "check_example"
PLUGIN_VERSION = "1.0.0"

STATE_OK = 0
STATE_WARNING = 1
STATE_CRITICAL = 2
STATE_UNKNOWN = 3


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=f"{PLUGIN_NAME} v{PLUGIN_VERSION}"
    )
    parser.add_argument("-H", "--host", required=True, help="Target hostname or IP")
    parser.add_argument("-w", "--warning", type=float, required=True, help="Warning threshold")
    parser.add_argument("-c", "--critical", type=float, required=True, help="Critical threshold")
    parser.add_argument("-t", "--timeout", type=int, default=30, help="Timeout in seconds (default: 30)")
    parser.add_argument("-V", "--version", action="version", version=f"{PLUGIN_NAME} v{PLUGIN_VERSION}")
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    try:
        value = 42.0
        perfdata = f"metric={value};{args.warning};{args.critical};0;100"
        print(f"{PLUGIN_NAME} OK - Everything looks good | {perfdata}")
        sys.exit(STATE_OK)

    except Exception as e:  # noqa: BLE001
        print(f"{PLUGIN_NAME} UNKNOWN - Unexpected error: {e}")
        sys.exit(STATE_UNKNOWN)


if __name__ == "__main__":
    main()

### Standards
- Always wrap logic in try/except, return UNKNOWN on unexpected errors
- Never use bare sys.exit() outside main()
- Type hints required
- Pin all dependency versions in requirements.txt
- Never hardcode credentials or paths

---

## Linting (Enforced)

All plugins MUST pass linting before merge. Enforced via GitHub Actions on push and PR.

### Bash - ShellCheck
- Zero warnings or errors permitted
- Minimum version: 0.9.0
- Use .shellcheckrc in repo root for justified project-wide exclusions
  shellcheck plugins/bash/check_example/check_example.sh

### Python - ruff
- Zero warnings or errors permitted
- Minimum version: 0.4.0
- Config in pyproject.toml
  ruff check plugins/python/check_example/check_example.py

---

## Icinga 2 Configuration Files

### Conf File Conventions
- One file per object type: checkcommand.conf, host_template.conf, service.conf
- Always use PluginDir - never hardcode paths
- Always include description for each argument
- Always set sensible default vars in CheckCommand
- Header comment block at top of every conf file:
    // check_example - CheckCommand Definition
    // Part of: https://github.com/isw-kudos/icinga-plugins
    // Docs: plugins/bash/check_example/INSTALL.md
    // Minimum Icinga 2 version: 2.13.0
- Service apply rules MUST include at least one assign where example

### checkcommand.conf Template

// check_example - CheckCommand Definition
// Part of: https://github.com/isw-kudos/icinga-plugins
// Docs: plugins/bash/check_example/INSTALL.md
// Minimum Icinga 2 version: 2.13.0

object CheckCommand "check_example" {
  command = [ PluginDir + "/check_example" ]

  arguments = {
    "-H" = {
      value       = "$check_example_host$"
      description = "Target hostname or IP"
      required    = true
    }
    "-w" = {
      value       = "$check_example_warning$"
      description = "Warning threshold"
      required    = true
    }
    "-c" = {
      value       = "$check_example_critical$"
      description = "Critical threshold"
      required    = true
    }
    "-t" = {
      value       = "$check_example_timeout$"
      description = "Timeout in seconds"
    }
  }

  vars.check_example_host     = "$address$"
  vars.check_example_warning  = 80
  vars.check_example_critical = 90
  vars.check_example_timeout  = 30
}

### host_template.conf Template
Include only when the plugin warrants a dedicated host template.

// check_example - Host Template
// Part of: https://github.com/isw-kudos/icinga-plugins
// Docs: plugins/bash/check_example/INSTALL.md
// Minimum Icinga 2 version: 2.13.0

template Host "example-host-template" {
  check_command = "hostalive"

  vars.check_example_warning  = 80
  vars.check_example_critical = 90
}

### service.conf Template

// check_example - Service Definition
// Part of: https://github.com/isw-kudos/icinga-plugins
// Docs: plugins/bash/check_example/INSTALL.md
// Minimum Icinga 2 version: 2.13.0

apply Service "check_example" {
  check_command = "check_example"

  vars.check_example_warning  = host.vars.check_example_warning
  vars.check_example_critical = host.vars.check_example_critical

  assign where host.vars.check_example == true
  // or: assign where "example-host-template" in host.templates
}

---

## Per-Plugin Documentation Structure

Each plugin directory MUST contain:

  check_example/
    check_example.sh    (or .py)
    README.md
    INSTALL.md
    CHANGELOG.md
    icinga2/
      checkcommand.conf
      host_template.conf    (if applicable)
      service.conf

---

## README.md Template (per plugin)

# check_example

Brief description of what this plugin checks.

## Requirements
- Icinga 2 >= 2.13.0
- Bash >= 4.x / Python >= 3.8
- List additional dependencies

## Compatibility
See Compatibility Matrix below.

## Usage
  check_example -H <host> -w <warning> -c <critical> [-t <timeout>] [-V] [-h]

## Arguments

| Argument            | Required | Default | Description           |
|---------------------|----------|---------|-----------------------|
| -H / --host         | Yes      |         | Target hostname or IP |
| -w / --warning      | Yes      | 80      | Warning threshold     |
| -c / --critical     | Yes      | 90      | Critical threshold    |
| -t / --timeout      | No       | 30      | Timeout in seconds    |
| -V / --version      | No       |         | Show plugin version   |
| -h / --help         | No       |         | Show help             |

## Example Output
  CHECK_EXAMPLE OK - Everything looks good | metric=42;80;90;0;100

## Known Limitations
- List known issues or edge cases here

## Compatibility Matrix

| Plugin Version | Icinga 2 Version | OS                     | Lang Version |
|----------------|------------------|------------------------|--------------|
| 1.0.0          | >= 2.13.0        | Ubuntu 22.04/24.04     | Bash 5.x     |
| 1.0.0          | >= 2.13.0        | Debian 11/12           | Bash 5.x     |
| 1.0.0          | >= 2.13.0        | RHEL / Rocky Linux 8/9 | Bash 4.x     |

## License
MIT - see LICENSE

---

## INSTALL.md Template (per plugin)

# Installation Guide: check_example

## Table of Contents
- Requirements
- Plugin Installation
- Method 1: Config File Deployment
  - CheckCommand Definition
  - Host Template (if applicable)
  - Service Definition
- Method 2: Icinga Director (UI)
  - Create CheckCommand
  - Create Host Template (if applicable)
  - Create Service
- Verification

## Requirements
- Icinga 2 >= 2.13.0
- Bash >= 4.x / Python >= 3.8
- List additional dependencies

## Plugin Installation

  cp check_example /usr/lib/nagios/plugins/check_example
  chmod +x /usr/lib/nagios/plugins/check_example

If using satellite/agent setup, install the plugin on the node executing the
check, not necessarily the Icinga 2 master.

## Method 1: Config File Deployment

### CheckCommand Definition

  cp icinga2/checkcommand.conf /etc/icinga2/conf.d/check_example_command.conf

See icinga2/checkcommand.conf for full contents.

### Host Template
Omit if not applicable.

  cp icinga2/host_template.conf /etc/icinga2/conf.d/check_example_host_template.conf

See icinga2/host_template.conf for full contents.

### Service Definition

  cp icinga2/service.conf /etc/icinga2/conf.d/check_example_service.conf

See icinga2/service.conf for full contents.
Adjust the assign where rule to match your environment before deploying.

Validate and reload Icinga 2:

  icinga2 daemon --validate
  systemctl reload icinga2

## Method 2: Icinga Director (UI)

Assumes Icinga Director is installed and Kickstart wizard completed.
Minimum supported Director version: 1.10.0

### Create CheckCommand

1. Navigate to Icinga Director > Commands > External Commands
2. Click + Add
3. Fill in:

  Name:        check_example
  Command:     $USER1$/check_example
  Description: Brief description of what it checks

4. Switch to Arguments tab and add:

  Argument | Value                       | Required | Description
  -H       | $check_example_host$        | Yes      | Target hostname or IP
  -w       | $check_example_warning$     | Yes      | Warning threshold
  -c       | $check_example_critical$    | Yes      | Critical threshold
  -t       | $check_example_timeout$     | No       | Timeout in seconds

5. Click Store then Deploy

### Create Host Template
Omit if not applicable.

1. Navigate to Icinga Director > Hosts > Host Templates
2. Click + Add
3. Fill in:

  Name:          example-host-template
  Check command: hostalive

4. Switch to Custom Properties tab and add:

  check_example_warning  = 80
  check_example_critical = 90

5. Click Store

### Create Service

1. Navigate to Icinga Director > Services > Apply Rules
2. Click + Add
3. Fill in:

  Name:          check_example
  Check command: check_example

4. Switch to Custom Properties tab:

  check_example_warning  = 80
  check_example_critical = 90

5. Switch to Assign tab and add rule:
   - host.vars.check_example is true
   - or: host.templates contains example-host-template

6. Click Store then Deploy

Always trigger a Deploy after changes in Director. Changes are not active until deployed.

Sensitive values (passwords, tokens): Do not hardcode as default vars. Set at host
level or use Icinga 2 constants. In Director, use Data Fields with type String and
advise use of a secrets store integration.

## Verification

  /usr/lib/nagios/plugins/check_example -H 127.0.0.1 -w 80 -c 90

Expected output:
  CHECK_EXAMPLE OK - Everything looks good | metric=42;80;90;0;100

  icinga2 object list --type Service --name "check_example"
  journalctl -u icinga2 -f

---

## CHANGELOG.md Format (per plugin)

# Changelog: check_example

## [Unreleased]

## [1.0.0] - YYYY-MM-DD
### Added
- Initial release
- Supports -H, -w, -c, -t arguments
- Performance data output

---

## Versioning Bump Rules

  MAJOR = Argument removed, renamed, or output format changed
  MINOR = New argument, new metric, new feature added
  PATCH = Bug fix, docs update, refactor with no behaviour change

---

## Repository README.md Requirements

Root README.md MUST always contain and keep updated:

### Plugin Index Table

  | Plugin        | Language | Description           | Version | Status |
  |---------------|----------|-----------------------|---------|--------|
  | check_example | Bash     | Checks example metric | 1.0.0   | Stable |

  Status values: Stable, Beta, Deprecated

### Compatibility Matrix

  | Plugin        | Icinga 2  | OS                     | Lang Version |
  |---------------|-----------|------------------------|--------------|
  | check_example | >= 2.13.0 | Ubuntu 22.04/24.04     | Bash 5.x     |
  | check_example | >= 2.13.0 | Debian 11/12           | Bash 5.x     |
  | check_example | >= 2.13.0 | RHEL / Rocky Linux 8/9 | Bash 4.x     |
