#!/usr/bin/env bash

extract_report() {
    local perf_data="$1"
    perf report -i "$perf_data" --stdio --sort=overhead,symbol -g none 2>/dev/null | grep -E '^\s*[0-9]+\.[0-9]+%' || true
}

phase_pct() {
    local report_file="$1" regex="$2"
    (grep -E "$regex" "$report_file" || true) | awk '{gsub("%","",$1); sum+=$1} END {printf "%.4f", sum+0}'
}

pct_to_seconds() {
    awk -v p="$1" -v t="$2" 'BEGIN {printf "%.4f", p/100.0*t}'
}
