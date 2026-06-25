#!/usr/bin/env python3
# MIT License
# Copyright (c) 2025 ISW Kudos
# https://github.com/isw-kudos/icinga-plugins/blob/main/LICENSE

"""
check_k8s_workloads - Icinga 2 plugin to alert on Kubernetes Deployment and
StatefulSet replica health.

For each workload it compares spec.replicas to status.readyReplicas and flags
under-replication, fully-down workloads, and stalled rollouts (detected via
metadata.generation > status.observedGeneration or the Deployment Progressing
condition with ProgressDeadlineExceeded).
"""

from __future__ import annotations

import argparse
import signal
import sys
from typing import Any

PLUGIN_NAME = "check_k8s_workloads"
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


def deployment_progressing_state(workload: Any) -> str | None:
    """Return 'stalled' if a Deployment's Progressing condition shows
    ProgressDeadlineExceeded, else None.
    """
    conditions = (workload.status.conditions or []) if workload.status else []
    for cond in conditions:
        if cond.type == "Progressing":
            if cond.status == "False" and cond.reason == "ProgressDeadlineExceeded":
                return "stalled"
    return None


def evaluate_workload(workload: Any, kind: str) -> tuple[int, str, int, int]:
    """Evaluate a Deployment or StatefulSet.

    Returns (state, message_if_not_ok, desired_replicas, ready_replicas).
    """
    meta = workload.metadata
    spec = workload.spec
    status = workload.status
    name = f"{meta.namespace}/{meta.name}"

    desired = spec.replicas if spec.replicas is not None else 0
    ready = (status.ready_replicas or 0) if status else 0
    available = (getattr(status, "available_replicas", None) or 0) if status else 0
    observed_gen = (status.observed_generation or 0) if status else 0
    gen = meta.generation or 0

    # A workload scaled to zero is intentional and OK.
    if desired == 0:
        return (STATE_OK, "", 0, 0)

    if kind == "Deployment" and deployment_progressing_state(workload) == "stalled":
        return (
            STATE_CRITICAL,
            f"{kind} {name} rollout stalled (ProgressDeadlineExceeded), ready={ready}/{desired}",
            desired,
            ready,
        )

    if ready == 0:
        return (
            STATE_CRITICAL,
            f"{kind} {name} 0/{desired} ready",
            desired,
            ready,
        )

    if ready < desired:
        return (
            STATE_WARNING,
            f"{kind} {name} {ready}/{desired} ready",
            desired,
            ready,
        )

    # Ready count matches desired but rollout still in progress.
    if observed_gen and gen > observed_gen:
        return (
            STATE_WARNING,
            f"{kind} {name} rollout in progress (generation {observed_gen}->{gen})",
            desired,
            ready,
        )

    # For Deployments, available_replicas tracks minReadySeconds satisfaction.
    if kind == "Deployment" and available < desired:
        return (
            STATE_WARNING,
            f"Deployment {name} ready={ready}/{desired} but available={available}",
            desired,
            ready,
        )

    return (STATE_OK, "", desired, ready)


def list_workloads(
    api_client: Any, args: argparse.Namespace
) -> tuple[list[Any], list[Any]]:
    from kubernetes import client  # type: ignore

    apps = client.AppsV1Api(api_client)
    deployments: list[Any] = []
    statefulsets: list[Any] = []
    excluded = set(args.exclude_namespace)
    selector = args.selector or ""

    if args.include_deployments:
        if args.namespace:
            for ns in args.namespace:
                resp = apps.list_namespaced_deployment(
                    namespace=ns,
                    label_selector=selector,
                    timeout_seconds=args.timeout,
                )
                deployments.extend(resp.items)
        else:
            resp = apps.list_deployment_for_all_namespaces(
                label_selector=selector,
                timeout_seconds=args.timeout,
            )
            deployments.extend(
                d for d in resp.items if d.metadata.namespace not in excluded
            )

    if args.include_statefulsets:
        if args.namespace:
            for ns in args.namespace:
                resp = apps.list_namespaced_stateful_set(
                    namespace=ns,
                    label_selector=selector,
                    timeout_seconds=args.timeout,
                )
                statefulsets.extend(resp.items)
        else:
            resp = apps.list_stateful_set_for_all_namespaces(
                label_selector=selector,
                timeout_seconds=args.timeout,
            )
            statefulsets.extend(
                s for s in resp.items if s.metadata.namespace not in excluded
            )

    return deployments, statefulsets


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
        "-n",
        "--namespace",
        action="append",
        help="Namespace to check (repeatable). Default: all namespaces.",
    )
    parser.add_argument(
        "--exclude-namespace",
        action="append",
        default=[],
        help="Namespace to skip (repeatable). Ignored when -n is given.",
    )
    parser.add_argument(
        "-l",
        "--selector",
        help="Label selector, e.g. 'app=nginx,tier!=cache'",
    )
    parser.add_argument(
        "--no-deployments",
        dest="include_deployments",
        action="store_false",
        help="Do not check Deployments",
    )
    parser.add_argument(
        "--no-statefulsets",
        dest="include_statefulsets",
        action="store_false",
        help="Do not check StatefulSets",
    )
    parser.set_defaults(include_deployments=True, include_statefulsets=True)
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
        help="Show OK workloads in output as well.",
    )
    parser.add_argument(
        "-V",
        "--version",
        action="version",
        version=f"{PLUGIN_NAME} v{PLUGIN_VERSION}",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    if args.timeout < 1:
        print(f"{PLUGIN_NAME} UNKNOWN - timeout must be >= 1 second")
        sys.exit(STATE_UNKNOWN)
    if not args.include_deployments and not args.include_statefulsets:
        print(f"{PLUGIN_NAME} UNKNOWN - nothing to check (--no-deployments and --no-statefulsets)")
        sys.exit(STATE_UNKNOWN)

    signal.signal(signal.SIGALRM, _timeout_handler)
    signal.alarm(args.timeout)

    try:
        api_client = build_api_client(args)
        deployments, statefulsets = list_workloads(api_client, args)
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

    total = len(deployments) + len(statefulsets)
    if total == 0:
        scope = ",".join(args.namespace) if args.namespace else "all namespaces"
        sel = f" selector={args.selector}" if args.selector else ""
        print(f"{PLUGIN_NAME} OK - no workloads found in {scope}{sel}")
        sys.exit(STATE_OK)

    worst_state = STATE_OK
    bad_lines: list[str] = []
    ok_lines: list[str] = []
    counts = {STATE_OK: 0, STATE_WARNING: 0, STATE_CRITICAL: 0}
    desired_total = 0
    ready_total = 0

    for kind, items in (("Deployment", deployments), ("StatefulSet", statefulsets)):
        for w in items:
            state, message, desired, ready = evaluate_workload(w, kind)
            counts[state] = counts.get(state, 0) + 1
            desired_total += desired
            ready_total += ready
            if state > worst_state:
                worst_state = state
            if state == STATE_OK:
                if args.verbose:
                    ok_lines.append(
                        f"[OK] {kind} {w.metadata.namespace}/{w.metadata.name}"
                        f" {ready}/{desired}"
                    )
            else:
                bad_lines.append(f"[{STATE_NAMES[state]}] {message}")

    ok_count = counts[STATE_OK]
    warn_count = counts[STATE_WARNING]
    crit_count = counts[STATE_CRITICAL]

    if worst_state == STATE_OK:
        summary = f"All {total} workload(s) healthy ({ready_total}/{desired_total} replicas ready)"
    else:
        summary = (
            f"{ok_count}/{total} workload(s) OK"
            f" ({ready_total}/{desired_total} replicas ready)"
        )
        if crit_count:
            summary += f", {crit_count} CRITICAL"
        if warn_count:
            summary += f", {warn_count} WARNING"

    perfdata = (
        f"workloads_total={total} workloads_ok={ok_count}"
        f" workloads_warning={warn_count};;;0 workloads_critical={crit_count};;;0"
        f" replicas_desired={desired_total} replicas_ready={ready_total}"
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
