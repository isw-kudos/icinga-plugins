#!/usr/bin/env python3
# MIT License
# Copyright (c) 2025 ISW Kudos
# https://github.com/isw-kudos/icinga-plugins/blob/main/LICENSE

"""
check_nfs_mount - Icinga 2 plugin to verify NFS mounts are correctly mounted and accessible.
"""

from __future__ import annotations

import argparse
import os
import signal
import sys
import time

PLUGIN_NAME = "check_nfs_mount"
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


class MountTimeoutError(Exception):
    pass


def _timeout_handler(signum: int, frame: object) -> None:
    raise MountTimeoutError("Operation timed out")


def parse_mounts() -> dict[str, tuple[str, str]]:
    """Parse /proc/mounts and return a dict mapping mount_point -> (source, fstype)."""
    mounts: dict[str, tuple[str, str]] = {}
    try:
        with open("/proc/mounts") as f:
            for line in f:
                parts = line.split()
                if len(parts) < 3:
                    continue
                # Mount points in /proc/mounts have spaces escaped as \040
                source = parts[0].replace("\\040", " ")
                target = parts[1].replace("\\040", " ")
                fstype = parts[2]
                mounts[target] = (source, fstype)
    except (IOError, OSError) as e:
        raise RuntimeError(f"Cannot read /proc/mounts: {e}") from e
    return mounts


def check_mount(
    mount_point: str,
    mounts: dict[str, tuple[str, str]],
    timeout: int,
    check_write: bool = False,
) -> tuple[int, str, float]:
    """Check a single mount point. Returns (state, message, elapsed_ms)."""
    normalized = mount_point.rstrip("/") or "/"

    if normalized not in mounts:
        return (STATE_CRITICAL, f"{mount_point} is not mounted", 0.0)

    source, fstype = mounts[normalized]

    if not fstype.startswith("nfs"):
        return (
            STATE_CRITICAL,
            (
                f"{mount_point} is mounted but filesystem type is"
                f" '{fstype}', not NFS (source: {source})"
            ),
            0.0,
        )

    # SIGALRM is used because stale/hung NFS mounts block stat()/listdir()
    # in uninterruptible sleep — a regular threading.Timer cannot interrupt that.
    signal.signal(signal.SIGALRM, _timeout_handler)
    signal.alarm(timeout)

    start = time.monotonic()
    try:
        os.stat(normalized)
        os.listdir(normalized)

        if check_write:
            test_file = os.path.join(normalized, f".icinga_nfs_check_{os.getpid()}")
            try:
                with open(test_file, "w") as f:
                    f.write("icinga nfs check\n")
                os.remove(test_file)
            except (IOError, OSError) as e:
                signal.alarm(0)
                elapsed = (time.monotonic() - start) * 1000
                return (
                    STATE_CRITICAL,
                    f"{mount_point} (NFS {source}) is mounted but not writable: {e}",
                    elapsed,
                )
    except MountTimeoutError:
        elapsed = (time.monotonic() - start) * 1000
        return (
            STATE_CRITICAL,
            (
                f"{mount_point} (NFS {source}) is unresponsive"
                f" (timeout after {timeout}s) - likely stale mount"
            ),
            elapsed,
        )
    except (IOError, OSError) as e:
        signal.alarm(0)
        elapsed = (time.monotonic() - start) * 1000
        return (
            STATE_CRITICAL,
            f"{mount_point} (NFS {source}) is mounted but not accessible: {e}",
            elapsed,
        )
    finally:
        signal.alarm(0)

    elapsed = (time.monotonic() - start) * 1000
    mode = "rw" if check_write else "ro-checked"
    return (
        STATE_OK,
        f"{mount_point} (NFS {source}, {mode}) is mounted and accessible",
        elapsed,
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=f"{PLUGIN_NAME} v{PLUGIN_VERSION}",
    )
    parser.add_argument(
        "-m",
        "--mount",
        action="append",
        required=True,
        metavar="PATH",
        help="NFS mount point to check. Can be specified multiple times.",
    )
    parser.add_argument(
        "-t",
        "--timeout",
        type=int,
        default=10,
        help="Timeout in seconds per mount check (default: 10)",
    )
    parser.add_argument(
        "-w",
        "--check-write",
        action="store_true",
        help="Also verify the mount is writable by creating and deleting a test file.",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="Show per-mount detail in output even when OK.",
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

    try:
        mounts = parse_mounts()
    except RuntimeError as e:
        print(f"{PLUGIN_NAME} UNKNOWN - {e}")
        sys.exit(STATE_UNKNOWN)

    results: list[tuple[str, int, str, float]] = []
    worst_state = STATE_OK

    for mp in args.mount:
        state, message, elapsed = check_mount(
            mp, mounts, args.timeout, check_write=args.check_write
        )
        results.append((mp, state, message, elapsed))
        if state > worst_state:
            worst_state = state

    total = len(results)
    ok_count = sum(1 for r in results if r[1] == STATE_OK)
    crit_count = sum(1 for r in results if r[1] == STATE_CRITICAL)
    warn_count = sum(1 for r in results if r[1] == STATE_WARNING)

    if worst_state == STATE_OK:
        summary = f"All {total} NFS mount(s) OK"
    else:
        summary = f"{ok_count}/{total} NFS mount(s) OK"
        if crit_count:
            summary += f", {crit_count} CRITICAL"
        if warn_count:
            summary += f", {warn_count} WARNING"

    detail_lines = []
    for _mp, state, message, _elapsed in results:
        if state != STATE_OK or args.verbose:
            detail_lines.append(f"[{STATE_NAMES[state]}] {message}")

    perfdata_parts = []
    for mp, _state, _message, elapsed in results:
        label = mp.replace(" ", "_").replace("=", "_").replace("'", "")
        perfdata_parts.append(f"'{label}_response_ms'={elapsed:.2f}ms")
    perfdata = " ".join(perfdata_parts)

    first_line = f"{PLUGIN_NAME} {STATE_NAMES[worst_state]} - {summary}"
    if perfdata:
        first_line += f" | {perfdata}"

    output_parts = [first_line]
    if detail_lines:
        output_parts.extend(detail_lines)

    print("\n".join(output_parts))
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
