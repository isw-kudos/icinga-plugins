#!/usr/bin/env python3
# MIT License
# Copyright (c) 2025 ISW Kudos
# https://github.com/isw-kudos/icinga-plugins/blob/main/LICENSE

"""
check_k8s_pods - Icinga 2 plugin to alert on Kubernetes pod health.

Reports pods that are not Running/Ready, that are stuck in failed image-pull
or CrashLoopBackOff states, that have been Pending beyond a grace period, or
whose container restart counts exceed configurable thresholds.
"""

from __future__ import annotations

import argparse
import signal
import sys
from datetime import datetime, timezone
from typing import Any

PLUGIN_NAME = "check_k8s_pods"
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

# Container waiting-state reasons that indicate the pod will not recover without intervention.
CRITICAL_WAITING_REASONS = {
    "CrashLoopBackOff",
    "ImagePullBackOff",
    "ErrImagePull",
    "InvalidImageName",
    "CreateContainerConfigError",
    "CreateContainerError",
    "RunContainerError",
    "ContainerCannotRun",
}


class PluginTimeoutError(Exception):
    pass


def _timeout_handler(signum: int, frame: object) -> None:
    raise PluginTimeoutError("Plugin timed out")


def build_api_client(args: argparse.Namespace) -> Any:
    """Return a kubernetes.client.ApiClient built from CLI args.

    Imported lazily so --version / --help work without the kubernetes package installed.
    """
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


def parse_age_seconds(timestamp: Any) -> float:
    """Return seconds since a Kubernetes timestamp (may be datetime or None)."""
    if timestamp is None:
        return 0.0
    if isinstance(timestamp, datetime):
        ts = timestamp
    else:
        try:
            ts = datetime.fromisoformat(str(timestamp).replace("Z", "+00:00"))
        except ValueError:
            return 0.0
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=timezone.utc)
    return (datetime.now(timezone.utc) - ts).total_seconds()


def evaluate_pod(
    pod: Any,
    restart_warn: int,
    restart_crit: int,
    pending_grace: int,
) -> tuple[int, str, int]:
    """Evaluate a single pod. Returns (state, reason_or_empty, max_restarts)."""
    meta = pod.metadata
    status = pod.status
    name = f"{meta.namespace}/{meta.name}"

    phase = status.phase or "Unknown"

    # Pod-level terminal failures.
    if phase == "Failed":
        reason = status.reason or "Failed"
        return (STATE_CRITICAL, f"{name} phase=Failed reason={reason}", 0)
    if phase == "Unknown":
        return (STATE_CRITICAL, f"{name} phase=Unknown (node lost?)", 0)

    # Pods that have completed successfully (e.g. Jobs) are healthy.
    if phase == "Succeeded":
        return (STATE_OK, "", 0)

    max_restarts = 0
    container_statuses = list(status.container_statuses or []) + list(
        status.init_container_statuses or []
    )

    for cs in container_statuses:
        if cs.restart_count and cs.restart_count > max_restarts:
            max_restarts = cs.restart_count

        waiting = getattr(cs.state, "waiting", None) if cs.state else None
        if waiting and waiting.reason in CRITICAL_WAITING_REASONS:
            return (
                STATE_CRITICAL,
                f"{name} container={cs.name} waiting={waiting.reason}",
                max_restarts,
            )

        terminated = getattr(cs.state, "terminated", None) if cs.state else None
        if terminated and terminated.exit_code and terminated.exit_code != 0:
            # Only flag terminated-with-error when the pod is not Succeeded overall.
            if phase != "Succeeded":
                return (
                    STATE_CRITICAL,
                    (
                        f"{name} container={cs.name} terminated exit={terminated.exit_code}"
                        f" reason={terminated.reason or '?'}"
                    ),
                    max_restarts,
                )

    if phase == "Pending":
        age = parse_age_seconds(meta.creation_timestamp)
        if age > pending_grace:
            return (
                STATE_CRITICAL,
                f"{name} stuck Pending for {int(age)}s (>{pending_grace}s grace)",
                max_restarts,
            )
        return (STATE_OK, "", max_restarts)

    # phase == "Running" past this point.
    not_ready = [
        cs.name for cs in (status.container_statuses or []) if not cs.ready
    ]

    if max_restarts >= restart_crit:
        return (
            STATE_CRITICAL,
            f"{name} restarts={max_restarts} (>={restart_crit})",
            max_restarts,
        )

    if not_ready:
        return (
            STATE_WARNING,
            f"{name} Running but containers not ready: {', '.join(not_ready)}",
            max_restarts,
        )

    if max_restarts >= restart_warn:
        return (
            STATE_WARNING,
            f"{name} restarts={max_restarts} (>={restart_warn})",
            max_restarts,
        )

    return (STATE_OK, "", max_restarts)


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
        "-w",
        "--restart-warning",
        type=int,
        default=5,
        help="WARNING when any container restart count >= this value (default: 5)",
    )
    parser.add_argument(
        "-c",
        "--restart-critical",
        type=int,
        default=20,
        help="CRITICAL when any container restart count >= this value (default: 20)",
    )
    parser.add_argument(
        "--pending-grace",
        type=int,
        default=300,
        help="Seconds a pod may remain Pending before CRITICAL (default: 300)",
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
        help="Show OK pods in output as well.",
    )
    parser.add_argument(
        "-V",
        "--version",
        action="version",
        version=f"{PLUGIN_NAME} v{PLUGIN_VERSION}",
    )
    return parser.parse_args()


def list_pods(api_client: Any, args: argparse.Namespace) -> list[Any]:
    from kubernetes import client  # type: ignore

    core = client.CoreV1Api(api_client)
    pods: list[Any] = []

    if args.namespace:
        for ns in args.namespace:
            resp = core.list_namespaced_pod(
                namespace=ns,
                label_selector=args.selector or "",
                timeout_seconds=args.timeout,
            )
            pods.extend(resp.items)
    else:
        resp = core.list_pod_for_all_namespaces(
            label_selector=args.selector or "",
            timeout_seconds=args.timeout,
        )
        excluded = set(args.exclude_namespace)
        pods.extend(p for p in resp.items if p.metadata.namespace not in excluded)

    return pods


def main() -> None:
    args = parse_args()

    if args.timeout < 1:
        print(f"{PLUGIN_NAME} UNKNOWN - timeout must be >= 1 second")
        sys.exit(STATE_UNKNOWN)
    if args.restart_critical < args.restart_warning:
        print(
            f"{PLUGIN_NAME} UNKNOWN - --restart-critical must be >= --restart-warning"
        )
        sys.exit(STATE_UNKNOWN)

    signal.signal(signal.SIGALRM, _timeout_handler)
    signal.alarm(args.timeout)

    try:
        api_client = build_api_client(args)
        pods = list_pods(api_client, args)
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

    total = len(pods)
    if total == 0:
        scope = ",".join(args.namespace) if args.namespace else "all namespaces"
        sel = f" selector={args.selector}" if args.selector else ""
        print(f"{PLUGIN_NAME} OK - no pods found in {scope}{sel}")
        sys.exit(STATE_OK)

    worst_state = STATE_OK
    bad_lines: list[str] = []
    ok_lines: list[str] = []
    state_counts = {STATE_OK: 0, STATE_WARNING: 0, STATE_CRITICAL: 0}
    max_restarts_overall = 0

    for pod in pods:
        state, reason, restarts = evaluate_pod(
            pod, args.restart_warning, args.restart_critical, args.pending_grace
        )
        state_counts[state] = state_counts.get(state, 0) + 1
        if restarts > max_restarts_overall:
            max_restarts_overall = restarts
        if state > worst_state:
            worst_state = state
        if state == STATE_OK:
            if args.verbose:
                ok_lines.append(
                    f"[OK] {pod.metadata.namespace}/{pod.metadata.name}"
                )
        else:
            bad_lines.append(f"[{STATE_NAMES[state]}] {reason}")

    ok_count = state_counts[STATE_OK]
    warn_count = state_counts[STATE_WARNING]
    crit_count = state_counts[STATE_CRITICAL]

    if worst_state == STATE_OK:
        summary = f"All {total} pod(s) healthy"
    else:
        summary = f"{ok_count}/{total} pod(s) OK"
        if crit_count:
            summary += f", {crit_count} CRITICAL"
        if warn_count:
            summary += f", {warn_count} WARNING"

    perfdata = (
        f"pods_total={total} pods_ok={ok_count} pods_warning={warn_count};;;0"
        f" pods_critical={crit_count};;;0 max_restarts={max_restarts_overall}"
        f";{args.restart_warning};{args.restart_critical};0"
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
