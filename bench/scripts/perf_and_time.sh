#!/usr/bin/env bash

set -euo pipefail

freq="$1"
out="$2"
shift 2
if [ "${1:-}" != "--" ]; then
    echo "usage: perf_and_time.sh <perf-freq> <output.perf.data> -- <command...>" >&2
    exit 1
fi
shift

start=$(date +%s.%N)
perf record -F "$freq" -g -o "$out" -- "$@" >&2
end=$(date +%s.%N)

awk -v s="$start" -v e="$end" 'BEGIN {printf "%.4f", e-s}'
