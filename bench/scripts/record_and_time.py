#!/usr/bin/env python3
"""Records a profiler trace of <command...> and prints its wall time (seconds).

Linux:  `perf record`, which launches the command itself.
macOS:  `perf` doesn't exist, so we use the `sample` CLI profiler (ships with
        the Xcode Command Line Tools). Unlike `perf record`, `sample` attaches
        to an already-running process by PID rather than launching one
        itself, so we background the target, sample it by PID, and wait for
        it to finish. `sample` itself polls the target and returns as soon as
        it exits, so the large duration cap below is only reached by a hung
        process, not normal runs - and since `sample` doesn't kill what it
        was sampling, we explicitly kill the target ourselves if it's still
        alive once that cap is hit.

On both platforms the target's own stdout is redirected to our stderr, so
whatever it prints (e.g. "Seconds: ... / Primes: ...") can't get mixed into
the wall-time value we print on stdout.

Stdlib only, no third-party dependencies.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import time
from pathlib import Path


def usage() -> int:
    print(
        "usage: record_and_time.py <freq-hz> <output-file> -- <command...>",
        file=sys.stderr,
    )
    return 1


def record_linux(freq: str, out: str, command: list[str]) -> float:
    if shutil.which("perf") is None:
        print("error: 'perf' not found on PATH.", file=sys.stderr)
        raise SystemExit(1)

    start = time.time()
    result = subprocess.run(
        ["perf", "record", "-F", freq, "-o", out, "--", *command],
        stdout=sys.stderr,
    )
    end = time.time()

    if result.returncode != 0:
        print(f"error: 'perf record' exited with status {result.returncode}", file=sys.stderr)
        raise SystemExit(result.returncode)

    return end - start


def record_mac(freq: str, out: str, command: list[str]) -> float:
    if shutil.which("sample") is None:
        print(
            "error: 'sample' not found on PATH. It ships with the Xcode "
            "Command Line Tools (xcode-select --install) on most macOS "
            "versions.",
            file=sys.stderr,
        )
        raise SystemExit(1)

    interval_ms = max(1, round(1000.0 / float(freq)))
    max_duration = 3600

    start = time.time()
    proc = subprocess.Popen(command, stdout=sys.stderr, stderr=sys.stderr)

    sample_result = subprocess.run(
        ["sample", str(proc.pid), str(max_duration), str(interval_ms), "-file", out],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    if sample_result.returncode != 0:
        print(
            "warning: 'sample' exited non-zero. On recent macOS it may need "
            "to run with elevated privileges to attach to another process "
            "(try re-running under sudo). Checking whether it still "
            "produced output...",
            file=sys.stderr,
        )

    # `sample` only polls for up to max_duration; it does not kill the
    # target. If the target is still alive once `sample` returns, it
    # outlived that cap (e.g. it's hung) - kill it here instead of blocking
    # forever on proc.wait().
    if proc.poll() is None:
        print(
            f"error: benchmark process (pid {proc.pid}) is still running "
            f"after the {max_duration}s sampling cap; treating it as hung "
            "and killing it.",
            file=sys.stderr,
        )
        proc.terminate()
        try:
            proc.wait(timeout=1)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        raise SystemExit(1)

    status = proc.wait()
    end = time.time()

    if not Path(out).is_file() or Path(out).stat().st_size == 0:
        print(f"error: sample produced no output at {out} - see any warning above.", file=sys.stderr)
        raise SystemExit(1)

    if status != 0:
        print(f"error: benchmarked command exited with status {status}", file=sys.stderr)
        raise SystemExit(status)

    return end - start


def main() -> int:
    args = sys.argv[1:]
    if len(args) < 4 or args[2] != "--":
        return usage()

    freq, out = args[0], args[1]
    command = args[3:]
    if not command:
        return usage()

    if sys.platform == "darwin":
        elapsed = record_mac(freq, out, command)
    else:
        elapsed = record_linux(freq, out, command)

    print(f"{elapsed:.4f}", end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
