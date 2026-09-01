"""Shared helpers for the bench scripts: turning a profiler recording (perf
data on Linux, `sample` text output on macOS) into normalized
(self-time-percent, symbol) rows, and slicing those rows into named phases.

Stdlib only, no third-party dependencies.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

Row = tuple[float, str]

# Self-time phase regexes, keyed by tool name - the single source of truth
# for both summarize.py's per-tool breakdown and compare.py's cross-tool
# table, so the two can't drift out of sync as symbol names change.
PHASES: dict[str, list[tuple[str, str]]] = {
    "primez": [
        ("small", r"segmentIterator\.smallSievePrimes\.SmallSievePrimes\.apply"),
        ("medium", r"segmentIterator\.mediumSievePrimes\.MediumSievePrimes\.(apply|activate)"),
        ("large", r"segmentIterator\.largeSievePrimes\.LargeSievePrimes\.applyBatch"),
        ("discovery", r"findSievePrimesInSegment"),
    ],
    "primesieve": [
        ("small", r"EratSmall::"),
        ("medium", r"EratMedium::"),
        ("large", r"EratBig::"),
    ],
}

MAC_SECTION_MARKER = "sort by top of stack"
# macOS `sample`'s leaf-symbol histogram lines look like:
#   "        some::Symbol::name(...)  (in binary)        1234"
# i.e. symbol text first, sample count last.
MAC_ROW_RE = re.compile(r"^\s*(.*\S)\s+(\d+)\s*$")
# Both `perf report --stdio` and our own normalized cache files use
# "<pct>%  <rest of line>".
PCT_LINE_RE = re.compile(r"^\s*([0-9]+(?:\.[0-9]+)?)%\s+(.*\S)\s*$")


def _parse_mac_sample(path: Path) -> list[Row]:
    lines = path.read_text(errors="replace").splitlines()

    start = None
    for i, line in enumerate(lines):
        if MAC_SECTION_MARKER in line.lower():
            start = i + 1
            break
    if start is None:
        raise RuntimeError(
            f"could not find a '{MAC_SECTION_MARKER}' section in {path} - "
            "sample's output format may have changed. First 20 lines:\n"
            + "\n".join(lines[:20])
        )

    counted: list[tuple[str, int]] = []
    for line in lines[start:]:
        if not line.strip():
            if counted:
                break
            continue
        m = MAC_ROW_RE.match(line)
        if m:
            counted.append((m.group(1), int(m.group(2))))

    if not counted:
        raise RuntimeError(f"no sample rows parsed from {path}")

    total = sum(count for _, count in counted)
    return [(100.0 * count / total, symbol) for symbol, count in counted]


def _parse_perf_report(path: Path) -> list[Row]:
    result = subprocess.run(
        [
            "perf", "report", "-i", str(path), "--stdio",
            "--sort=overhead,symbol", "-g", "none",
        ],
        capture_output=True, text=True,
    )
    rows: list[Row] = []
    for line in result.stdout.splitlines():
        m = PCT_LINE_RE.match(line)
        if m:
            rows.append((float(m.group(1)), m.group(2)))
    return rows


def extract_report(recording: Path) -> list[Row]:
    """Normalizes a raw recording into (self-time-pct, symbol) rows."""
    if sys.platform == "darwin":
        return _parse_mac_sample(recording)
    return _parse_perf_report(recording)


def write_report(rows: list[Row], path: Path) -> None:
    with open(path, "w") as f:
        for pct, symbol in rows:
            f.write(f"{pct:.4f}%  {symbol}\n")


def load_report(path: Path) -> list[Row]:
    """Reads back a cache file written by write_report()."""
    rows: list[Row] = []
    for line in Path(path).read_text().splitlines():
        m = PCT_LINE_RE.match(line)
        if m:
            rows.append((float(m.group(1)), m.group(2)))
    return rows


def phase_pct(rows: list[Row], regex: str) -> float:
    pattern = re.compile(regex)
    return sum(pct for pct, symbol in rows if pattern.search(symbol))


def pct_to_seconds(pct: float, total_seconds: float) -> float:
    return pct / 100.0 * total_seconds
