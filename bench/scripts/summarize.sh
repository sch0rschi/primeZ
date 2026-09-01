#!/usr/bin/env bash

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"

perf_data="$1"
total_seconds="$2"
report_cache="$3"
shift 3

if [ ! -f "$perf_data" ]; then
    echo "error: perf data file not found: $perf_data" >&2
    exit 1
fi

extract_report "$perf_data" > "$report_cache"

labels=()
regexes=()
for arg in "$@"; do
    labels+=("${arg%%=*}")
    regexes+=("${arg#*=}")
done

matched_total=0
printf '%-12s %8s %10s\n' "phase" "self%" "seconds"
printf '%-12s %8s %10s\n' "-----" "-----" "-------"

for i in "${!labels[@]}"; do
    label="${labels[$i]}"
    regex="${regexes[$i]}"
    pct=$(phase_pct "$report_cache" "$regex")
    seconds=$(pct_to_seconds "$pct" "$total_seconds")
    matched_total=$(awk -v a="$matched_total" -v b="$pct" 'BEGIN {printf "%.4f", a+b}')
    printf '%-12s %7s%% %9ss\n' "$label" "$pct" "$seconds"
done

other_pct=$(awk -v m="$matched_total" 'BEGIN {p=100.0-m; if (p<0) p=0; printf "%.4f", p}')
other_seconds=$(pct_to_seconds "$other_pct" "$total_seconds")
printf '%-12s %7s%% %9ss\n' "other" "$other_pct" "$other_seconds"
printf '%-12s %7s%% %9ss\n' "total" "100.0000" "$total_seconds"
