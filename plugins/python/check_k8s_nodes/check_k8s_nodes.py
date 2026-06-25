#!/usr/bin/env python3
# MIT License
# Copyright (c) 2025 ISW Kudos
# https://github.com/isw-kudos/icinga-plugins/blob/main/LICENSE

"""
check_k8s_nodes - Icinga 2 plugin to alert on Kubernetes node health.

Inspects each node's standard conditions: Ready (must be True),
MemoryPressure / DiskPressure / PIDPressure / NetworkUnavailable (must be False).
Also flags nodes that are cordoned (spec.unschedulable) as WARNING.
"""

from __future__ import annotations

import argparse
import signal
import sys
from typing import Any

PLUGIN_NAME = "check_k8s_nodes"
PLUGIN_VERSION = "1.0.0"

STATE_OK = 0
STATE_WARNING = 1
STATE_CRITICAL = 2
STATE_UNKNOWN = 3

STATE_NAMES: dict[int, str] = {
    STATE_OK: "OK",
    STATE_WARNING: "WARNING",
    STATE_CRITICAL: "CRITICAL",
    STATE_UNKNOWN: "UNKNOWN",
}

# Pressure conditions: True == bad, False == good.
PRESSURE_CONDITIONS = ("MemoryPressure", "DiskPressure", "PIDPressure", "NetworkUnavailable")


class PluginTimeoutError(Exception):
    pass


def _timeout_handler(signum: int, frame: object) -> None:
    raise PluginTimeoutError("Plugin timed out")


def build_api_client(args: argparse.Namespace) -> Any:
    try:
        from kubernetes import client, config  # type: ignore
    except ImportError as e:
        raise RuntimeError(
            "python 'kubernetes' package not installed (pip install kubernetes)"
        ) from e

    if args.kubeconfig:
        config.load_kube_config(config_file=args.kubeconfig, context=args.context)
        return client.ApiClient()

    if args.api_url and args.token:
        configuration = client.Configuration()
        configuration.host = args.api_url
        configuration.api_key = {"authorization": f"Bearer {args.token}"}
        if args.ca_cert:
            configuration.ssl_ca_cert = args.ca_cert
            configuration.verify_ssl = True
        elif args.insecure:
            configuration.verify_ssl = False
        else:
            configuration.verify_ssl = True
        return client.ApiClient(configuration)

    raise RuntimeError(
        "no auth: provide --kubeconfig or both --api-url and --token"
    )


def get_condition(node: Any, ctype: str) -> Any:
    for cond in (node.status.conditions or []) if node.status else []:
        if cond.type == ctype:
            return cond
    return None


def evaluate_node(
    node: Any, ignore_cordon: bool
) -> tuple[int, list[str]]:
    """Evaluate a single node. Returns (state, list_of_issues)."""
    name = node.metadata.name
    issues: list[str] = []
    state = STATE_OK

    ready = get_condition(node, "Ready")
    if ready is None:
        return (STATE_CRITICAL, [f"{name} has no Ready condition"])
    if ready.status != "True":
        reason = ready.reason or "Unknown"
        issues.append(f"{name} NotReady (reason={reason})")
        state = max(state, STATE_CRITICAL)

    for ctype in PRESSURE_CONDITIONS:
        cond = get_condition(node, ctype)
        if cond is None:
            continue
        if cond.status == "True":
            reason = cond.reason or ctype
            issues.append(f"{name} {ctype}=True (reason={reason})")
            state = max(state, STATE_CRITICAL)

    if not ignore_cordon and getattr(node.spec, "unschedulable", False):
        issues.append(f"{name} cordoned (spec.unschedulable=true)")
        state = max(state, STATE_WARNING)

    return (state, issues)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=f"{PLUGIN_NAME} v{PLUGIN_VERSION}",
    )
    parser.add_argument("--kubeconfig", help="Path to kubeconfig file")
    parser.add_argument(
        "--context", help="kubeconfig context to use (default: current-context)"
    )
    parser.add_argument("--api-url", help="Kubernetes API server URL (with --token)")
    parser.add_argument("--token", help="Bearer token (with --api-url)")
    parser.add_argument(
        "--ca-cert", help="CA certificate file for API server (with --api-url)"
    )
    parser.add_argument(
        "--insecure",
        action="store_true",
        help="Skip TLS verification (with --api-url). Not recommended.",
    )
    parser.add_argument(
        "-l",
        "--selector",
        help="Node label selector, e.g. 'role=worker'",
    )
    parser.add_argument(
        "--ignore-cordon",
        action="store_true",
        help="Do not WARN on cordoned (unschedulable) nodes",
    )
    parser.add_argument(
        "-t",
        "--timeout",
        type=int,
        default=30,
        help="Plugin timeout in seconds (default: 30)",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="Show OK nodes in output as well.",
    )
    parser.add_argument(
        "-V",
        "--version",
        action="version",
        version=f"{PLUGIN_NAME} v{PLUGIN_VERSION}",
    )
    return parser.parse_args()


def list_nodes(api_client: Any, args: argparse.Namespace) -> list[Any]:
    from kubernetes import client  # type: ignore

    core = client.CoreV1Api(api_client)
    resp = core.list_node(
        label_selector=args.selector or "",
        timeout_seconds=args.timeout,
    )
    return list(resp.items)


def main() -> None:
    args = parse_args()

    if args.timeout < 1:
        print(f"{PLUGIN_NAME} UNKNOWN - timeout must be >= 1 second")
        sys.exit(STATE_UNKNOWN)

    signal.signal(signal.SIGALRM, _timeout_handler)
    signal.alarm(args.timeout)

    try:
        api_client = build_api_client(args)
        nodes = list_nodes(api_client, args)
    except PluginTimeoutError:
        print(f"{PLUGIN_NAME} UNKNOWN - timed out after {args.timeout}s")
        sys.exit(STATE_UNKNOWN)
    except RuntimeError as e:
        print(f"{PLUGIN_NAME} UNKNOWN - {e}")
        sys.exit(STATE_UNKNOWN)
    except Exception as e:  # noqa: BLE001
        print(f"{PLUGIN_NAME} UNKNOWN - API error: {e}")
        sys.exit(STATE_UNKNOWN)
    finally:
        signal.alarm(0)

    total = len(nodes)
    if total == 0:
        sel = f" selector={args.selector}" if args.selector else ""
        print(f"{PLUGIN_NAME} UNKNOWN - no nodes found{sel}")
        sys.exit(STATE_UNKNOWN)

    worst_state = STATE_OK
    bad_lines: list[str] = []
    ok_lines: list[str] = []
    counts = {STATE_OK: 0, STATE_WARNING: 0, STATE_CRITICAL: 0}

    for node in nodes:
        state, issues = evaluate_node(node, args.ignore_cordon)
        counts[state] = counts.get(state, 0) + 1
        if state > worst_state:
            worst_state = state
        if state == STATE_OK:
            if args.verbose:
                ok_lines.append(f"[OK] {node.metadata.name}")
        else:
            for issue in issues:
                bad_lines.append(f"[{STATE_NAMES[state]}] {issue}")

    ok_count = counts[STATE_OK]
    warn_count = counts[STATE_WARNING]
    crit_count = counts[STATE_CRITICAL]

    if worst_state == STATE_OK:
        summary = f"All {total} node(s) Ready and healthy"
    else:
        summary = f"{ok_count}/{total} node(s) Ready"
        if crit_count:
            summary += f", {crit_count} CRITICAL"
        if warn_count:
            summary += f", {warn_count} WARNING"

    perfdata = (
        f"nodes_total={total} nodes_ready={ok_count}"
        f" nodes_warning={warn_count};;;0 nodes_critical={crit_count};;;0"
    )

    first_line = f"{PLUGIN_NAME} {STATE_NAMES[worst_state]} - {summary} | {perfdata}"
    output = [first_line, *bad_lines, *ok_lines]
    print("\n".join(output))
    sys.exit(worst_state)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print(f"{PLUGIN_NAME} UNKNOWN - interrupted")
        sys.exit(STATE_UNKNOWN)
    except Exception as e:  # noqa: BLE001
        print(f"{PLUGIN_NAME} UNKNOWN - unexpected error: {e}")
        sys.exit(STATE_UNKNOWN)
