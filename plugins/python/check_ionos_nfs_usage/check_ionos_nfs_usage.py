#!/usr/bin/env python3
# MIT License
# Copyright (c) 2025 ISW Kudos
# https://github.com/isw-kudos/icinga-plugins/blob/main/LICENSE

"""
check_ionos_nfs_usage - Checks that the shares on an IONOS Cloud Network File
Storage cluster together stay below the cluster's provisioned size.

Shares on an IONOS NFS cluster draw from one pool. When their combined usage
reaches the cluster size the cluster goes read-only for every share at once, so
the per-share quotas alone do not protect against it. This plugin reads the
cluster and all of its shares from the IONOS NFS API and compares the total
usage with the cluster size.
"""

import argparse
import json
import os
import re
import signal
import socket
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, List, Optional, Tuple

PLUGIN_NAME = "check_ionos_nfs_usage"
PLUGIN_VERSION = "1.0.0"

STATE_OK = 0
STATE_WARNING = 1
STATE_CRITICAL = 2
STATE_UNKNOWN = 3

STATE_NAMES: Dict[int, str] = {
    STATE_OK: "OK",
    STATE_WARNING: "WARNING",
    STATE_CRITICAL: "CRITICAL",
    STATE_UNKNOWN: "UNKNOWN",
}

TOKEN_ENV = "IONOS_TOKEN"
LOCATION_RE = re.compile(r"^[a-z]{2}-[a-z]{3}$")

# The API caps limit at 1000 and currently always returns a single page; the
# page cap only guards against a pagination loop that never ends.
PAGE_LIMIT = 1000
MAX_PAGES = 50

SIZE_UNITS: Dict[str, int] = {
    "GiB": 1024 ** 3,
    "TiB": 1024 ** 4,
}
MIB = 1024 ** 2

Json = Dict[str, Any]


class UsageError(Exception):
    """Bad command-line arguments."""


class CheckError(Exception):
    """The check cannot reach a verdict (API unreachable, bad data, ...)."""


class PluginTimeout(Exception):
    pass


class _Parser(argparse.ArgumentParser):
    # argparse exits 2 on a bad argument, which Icinga would report as
    # CRITICAL. Raise instead so main() can report UNKNOWN.
    def error(self, message: str) -> None:  # type: ignore[override]
        raise UsageError(message)


def _timeout_handler(signum: int, frame: object) -> None:
    raise PluginTimeout()


def parse_args() -> argparse.Namespace:
    parser = _Parser(
        description=f"{PLUGIN_NAME} v{PLUGIN_VERSION} - total share usage of an "
        "IONOS Cloud NFS cluster against its provisioned size",
        epilog=f"The API token is read from --token-file, or else from ${TOKEN_ENV}. "
        "There is deliberately no option to pass the token itself, because "
        "the command line is visible in the process list.",
    )
    where = parser.add_mutually_exclusive_group(required=True)
    where.add_argument(
        "-L",
        "--location",
        help="IONOS location of the cluster, e.g. de-fra, de-txl, gb-lhr",
    )
    where.add_argument(
        "-U",
        "--url",
        help="NFS API base URL, instead of --location (e.g. for a proxy)",
    )
    parser.add_argument(
        "-C",
        "--cluster",
        help="Cluster ID or name. May be omitted when the location has only one cluster.",
    )
    parser.add_argument(
        "--token-file",
        metavar="PATH",
        help=f"File whose first line is the IONOS API token (default: ${TOKEN_ENV})",
    )
    parser.add_argument(
        "-w",
        "--warning",
        type=float,
        default=80.0,
        help="Warning when usage reaches this percentage of the cluster size (default: 80)",
    )
    parser.add_argument(
        "-c",
        "--critical",
        type=float,
        default=90.0,
        help="Critical when usage reaches this percentage of the cluster size (default: 90)",
    )
    parser.add_argument(
        "-t",
        "--timeout",
        type=int,
        default=30,
        help="Timeout in seconds for the whole check (default: 30)",
    )
    parser.add_argument(
        "-V",
        "--version",
        action="version",
        version=f"{PLUGIN_NAME} v{PLUGIN_VERSION}",
    )
    return parser.parse_args()


def validate_args(args: argparse.Namespace) -> str:
    """Check argument values argparse cannot, and return the API base URL."""
    if args.timeout < 1:
        raise UsageError("timeout must be >= 1 second")
    for label, value in (("warning", args.warning), ("critical", args.critical)):
        if not 0 < value <= 100:
            raise UsageError(f"{label} must be a percentage between 0 and 100, got {value:g}")
    if args.warning > args.critical:
        raise UsageError(
            f"warning ({args.warning:g}%) must not be above critical ({args.critical:g}%)"
        )
    if args.url:
        return args.url.rstrip("/")
    if not LOCATION_RE.match(args.location):
        raise UsageError(f"location must look like 'de-fra', got '{args.location}'")
    return f"https://nfs.{args.location}.ionos.com"


def load_token(path: Optional[str]) -> str:
    if path:
        try:
            with open(path) as f:
                token = f.readline().strip()
        except (IOError, OSError) as e:
            raise CheckError(f"cannot read token file {path}: {e.strerror}") from e
        if not token:
            raise CheckError(f"token file {path} is empty")
        return token
    token = os.environ.get(TOKEN_ENV, "").strip()
    if not token:
        raise CheckError(f"no API token: pass --token-file or set {TOKEN_ENV}")
    return token


def _api_error_message(body: bytes) -> str:
    """Pull the human-readable message out of an IONOS Error response."""
    try:
        messages = json.loads(body.decode("utf-8")).get("messages") or []
        return "; ".join(m["message"] for m in messages if m.get("message"))
    except (ValueError, AttributeError, KeyError, TypeError):
        return ""


def api_get(
    base_url: str, path: str, token: str, params: Dict[str, Any], timeout: int
) -> Json:
    url = f"{base_url}{path}?{urllib.parse.urlencode(params)}"
    request = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
            "User-Agent": f"{PLUGIN_NAME}/{PLUGIN_VERSION}",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = response.read()
    except urllib.error.HTTPError as e:
        detail = _api_error_message(e.read())
        hint = {
            401: "the token is missing, invalid or expired",
            403: "the token's user lacks permission for Network File Storage",
            404: "not found",
            429: "rate limited by the API",
        }.get(e.code, "")
        reason = ": ".join(part for part in (hint, detail) if part)
        raise CheckError(f"HTTP {e.code} from {path}" + (f" - {reason}" if reason else "")) from e
    except urllib.error.URLError as e:
        if isinstance(e.reason, socket.timeout):
            raise PluginTimeout() from e
        raise CheckError(f"cannot reach {base_url}: {e.reason}") from e
    except socket.timeout as e:
        raise PluginTimeout() from e

    try:
        data = json.loads(body.decode("utf-8"))
    except ValueError as e:
        raise CheckError(f"response from {path} is not valid JSON") from e
    if not isinstance(data, dict):
        raise CheckError(f"unexpected response from {path}: not a JSON object")
    return data


def api_list(base_url: str, path: str, token: str, timeout: int) -> List[Json]:
    """Fetch every item of a paginated collection."""
    items: List[Json] = []
    offset = 0
    for _ in range(MAX_PAGES):
        page = api_get(base_url, path, token, {"offset": offset, "limit": PAGE_LIMIT}, timeout)
        batch = page.get("items") or []
        items.extend(batch)
        if not batch or not (page.get("_links") or {}).get("next"):
            return items
        offset += len(batch)
    raise CheckError(f"{path} returned more than {MAX_PAGES} pages")


def _name(resource: Json) -> str:
    return (resource.get("properties") or {}).get("name") or resource.get("id") or "?"


def select_cluster(clusters: List[Json], wanted: Optional[str]) -> Json:
    if wanted:
        matches = [c for c in clusters if wanted in (c.get("id"), _name(c))]
        if len(matches) == 1:
            return matches[0]
        if matches:
            raise CheckError(f"{len(matches)} clusters are named '{wanted}'; use the cluster ID")
        available = ", ".join(sorted(_name(c) for c in clusters)) or "none"
        raise CheckError(f"cluster '{wanted}' not found (available: {available})")
    if len(clusters) == 1:
        return clusters[0]
    if not clusters:
        raise CheckError("no NFS clusters found in this location")
    listing = ", ".join(f"{_name(c)} ({c.get('id')})" for c in clusters)
    raise CheckError(f"{len(clusters)} clusters found, select one with --cluster: {listing}")


def cluster_size_bytes(cluster: Json) -> int:
    props = cluster.get("properties") or {}
    size = props.get("size")
    unit = props.get("sizeUnit", "TiB")
    if not isinstance(size, int) or size <= 0:
        raise CheckError(f"cluster {_name(cluster)} reports no usable size ({size!r})")
    if unit not in SIZE_UNITS:
        raise CheckError(f"cluster {_name(cluster)} reports unknown size unit '{unit}'")
    return size * SIZE_UNITS[unit]


def fmt_bytes(value: float) -> str:
    for unit, factor in (("TiB", 1024 ** 4), ("GiB", 1024 ** 3), ("MiB", MIB), ("KiB", 1024)):
        if abs(value) >= factor:
            return f"{value / factor:.2f} {unit}"
    return f"{int(value)} B"


def perf_label(name: str) -> str:
    return "share_" + re.sub(r"[\s='|]", "_", name)


def evaluate(
    cluster: Json, shares: List[Json], warning: float, critical: float
) -> Tuple[int, str]:
    """Return (state, full plugin output) for a cluster and its shares."""
    name = _name(cluster)
    size = cluster_size_bytes(cluster)
    meta = cluster.get("metadata") or {}
    # The API reports 0 here when it cannot determine usage.
    cluster_used = int(meta.get("used") or 0)

    # (name, used bytes or None when not reported, quota bytes or 0 for none)
    rows: List[Tuple[str, Optional[int], int]] = []
    for share in shares:
        used = (share.get("metadata") or {}).get("used")
        quota_mib = (share.get("properties") or {}).get("quota") or 0
        rows.append((_name(share), int(used) if used is not None else None, int(quota_mib) * MIB))
    rows.sort(key=lambda r: -1 if r[1] is None else r[1], reverse=True)

    shares_used = sum(r[1] for r in rows if r[1] is not None)
    unreported = [r[0] for r in rows if r[1] is None]
    if unreported and cluster_used == 0:
        raise CheckError(
            f"usage not reported for share(s) {', '.join(unreported)}, "
            "and the cluster reports no usage either"
        )

    # The share total is what the cluster fills up with, but the cluster's own
    # figure also counts anything outside the shares and covers shares whose
    # usage is not reported. Alert on whichever is larger.
    used = max(shares_used, cluster_used)
    pct = used * 100.0 / size
    warn_bytes = int(size * warning / 100)
    crit_bytes = int(size * critical / 100)

    if pct >= critical:
        state, note = STATE_CRITICAL, f", critical at {critical:g}%"
    elif pct >= warning:
        state, note = STATE_WARNING, f", warning at {warning:g}%"
    else:
        state, note = STATE_OK, ""

    if used <= size:
        headroom = f"{fmt_bytes(size - used)} free"
    else:
        headroom = f"{fmt_bytes(used - size)} OVER"
    summary = (
        f"{name}: {fmt_bytes(used)} of {fmt_bytes(size)} used ({pct:.1f}%{note}), "
        f"{headroom}, {len(rows)} share(s)"
    )

    perfdata = [
        f"used={used}B;{warn_bytes};{crit_bytes};0;{size}",
        f"used_pct={pct:.2f}%;{warning:g};{critical:g};0;100",
        f"shares_used={shares_used}B;;;0;{size}",
        f"cluster_used={cluster_used}B;;;0;{size}",
    ]
    for share_name, share_used, quota in rows:
        if share_used is not None:
            perfdata.append(f"'{perf_label(share_name)}'={share_used}B;;;0;{quota or size}")

    props = cluster.get("properties") or {}
    details = [
        f"Cluster {name} ({cluster.get('id')}): status {meta.get('status', 'unknown')}, "
        f"size {props.get('size')} {props.get('sizeUnit', 'TiB')}",
        f"Usage: shares total {fmt_bytes(shares_used)}, cluster reports "
        f"{fmt_bytes(cluster_used)} (the check uses the larger)",
    ]
    if unreported:
        details.append(f"Usage not reported for: {', '.join(unreported)}")
    unlimited = sum(1 for r in rows if not r[2])
    if rows and not unlimited:
        quota_total = sum(r[2] for r in rows)
        over = " - overcommitted" if quota_total > size else ""
        details.append(f"Share quotas total {fmt_bytes(quota_total)} of {fmt_bytes(size)}{over}")
    elif unlimited:
        details.append(f"{unlimited} of {len(rows)} share(s) have no quota")
    if rows:
        details.append("Shares, largest first:")
    for share_name, share_used, quota in rows:
        if share_used is None:
            details.append(f"  {share_name}: usage not reported")
        elif quota:
            details.append(
                f"  {share_name}: {fmt_bytes(share_used)} "
                f"(quota {fmt_bytes(quota)}, {share_used * 100.0 / quota:.1f}%)"
            )
        else:
            details.append(f"  {share_name}: {fmt_bytes(share_used)} (no quota)")

    first_line = f"{PLUGIN_NAME} {STATE_NAMES[state]} - {summary} | {' '.join(perfdata)}"
    return state, "\n".join([first_line] + details)


def main() -> None:
    timeout = 0
    try:
        args = parse_args()
        base_url = validate_args(args)
        timeout = args.timeout
        token = load_token(args.token_file)

        # The alarm bounds the whole check; the socket timeout alone would
        # allow one full timeout per request.
        signal.signal(signal.SIGALRM, _timeout_handler)
        signal.alarm(timeout)

        clusters = api_list(base_url, "/clusters", token, timeout)
        cluster = select_cluster(clusters, args.cluster)
        shares = api_list(base_url, f"/clusters/{cluster.get('id')}/shares", token, timeout)
        state, output = evaluate(cluster, shares, args.warning, args.critical)

    except PluginTimeout:
        print(f"{PLUGIN_NAME} UNKNOWN - Plugin timed out after {timeout} seconds")
        sys.exit(STATE_UNKNOWN)
    except (UsageError, CheckError) as e:
        print(f"{PLUGIN_NAME} UNKNOWN - {e}")
        sys.exit(STATE_UNKNOWN)
    except Exception as e:  # noqa: BLE001
        print(f"{PLUGIN_NAME} UNKNOWN - Unexpected error: {e}")
        sys.exit(STATE_UNKNOWN)
    finally:
        signal.alarm(0)

    print(output)
    sys.exit(state)


if __name__ == "__main__":
    main()
