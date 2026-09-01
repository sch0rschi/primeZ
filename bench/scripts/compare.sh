#!/usr/bin/env bash

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"

pz_report="$1"; pz_total="$2"; ps_report="$3"; ps_total="$4"; primal_total="${5:-}"

for f in "$pz_report" "$ps_report"; do
    if [ ! -f "$f" ]; then
        echo "error: report cache not found: $f (run summarize.sh first)" >&2
        exit 1
    fi
done

PZ_SMALL='segmentIterator\.SegmentIterator\.applySmallSievePrimes'
PZ_MEDIUM='segmentIterator\.SegmentIterator\.(applyMediumSievePrimes|activateMediumSievePrimes)'
PZ_LARGE='applyLargeSievePrimesBatch'
PZ_DISCOVERY='findSievePrimesInSegment'

PS_SMALL='EratSmall::'
PS_MEDIUM='EratMedium::'
PS_LARGE='EratBig::'

pz_small=$(phase_pct "$pz_report" "$PZ_SMALL")
pz_medium=$(phase_pct "$pz_report" "$PZ_MEDIUM")
pz_large=$(phase_pct "$pz_report" "$PZ_LARGE")
pz_disc=$(phase_pct "$pz_report" "$PZ_DISCOVERY")
pz_other=$(awk -v a="$pz_small" -v b="$pz_medium" -v c="$pz_large" -v d="$pz_disc" \
    'BEGIN {p=100.0-(a+b+c+d); if (p<0) p=0; printf "%.4f", p}')

ps_small=$(phase_pct "$ps_report" "$PS_SMALL")
ps_medium=$(phase_pct "$ps_report" "$PS_MEDIUM")
ps_large=$(phase_pct "$ps_report" "$PS_LARGE")
ps_other=$(awk -v a="$ps_small" -v b="$ps_medium" -v c="$ps_large" \
    'BEGIN {p=100.0-(a+b+c); if (p<0) p=0; printf "%.4f", p}')

fmt_pct() { awk -v p="$1" 'BEGIN {printf "%.1f%%", p}'; }
fmt_sec() { awk -v s="$1" 'BEGIN {printf "%.2fs", s}'; }
ratio() {
    awk -v a="$1" -v b="$2" 'BEGIN { if (b+0 == 0) print "-"; else printf "%.2fx", a/b }'
}
dashes() { printf '%*s' "$1" '' | tr ' ' '-'; }

LW=11 PW=8 SW=9 RW=12 PSW=9 PRW=13
FMT="%-${LW}s | %${PW}s %${SW}s | %${PW}s %${SW}s   %${RW}s | %${PSW}s %${PRW}s\n"
GROUP_W=$((PW + 1 + SW))
PS_GROUP_W=$((GROUP_W + 3 + RW))
PRIMAL_GROUP_W=$((PSW + 1 + PRW))
HFMT="%-${LW}s | %-${GROUP_W}s | %-${PS_GROUP_W}s | %-${PRIMAL_GROUP_W}s\n"

row() {
    local label="$1" pz_pct="$2" ps_pct="$3" primal_s="${4:-}"
    local pzs pss r primal_col primal_r
    pzs=$(pct_to_seconds "$pz_pct" "$pz_total")
    pss=$(pct_to_seconds "$ps_pct" "$ps_total")
    r=$(ratio "$pzs" "$pss")
    if [ -n "$primal_s" ]; then
        primal_col=$(fmt_sec "$primal_s")
        primal_r=$(ratio "$pzs" "$primal_s")
    else
        primal_col="-"
        primal_r="-"
    fi
    printf "$FMT" "$label" "$(fmt_pct "$pz_pct")" "$(fmt_sec "$pzs")" \
        "$(fmt_pct "$ps_pct")" "$(fmt_sec "$pss")" "$r" "$primal_col" "$primal_r"
}

printf "$HFMT" "" "primeZ" "primesieve" "primal"
printf "$FMT" "phase" "self%" "seconds" "self%" "seconds" "primeZ/ps" "seconds" "primeZ/primal"
printf "$FMT" "$(dashes $LW)" "$(dashes $PW)" "$(dashes $SW)" "$(dashes $PW)" "$(dashes $SW)" \
    "$(dashes $RW)" "$(dashes $PSW)" "$(dashes $PRW)"
row "small"     "$pz_small"  "$ps_small"
row "medium"    "$pz_medium" "$ps_medium"
row "large"     "$pz_large"  "$ps_large"
row "discovery" "$pz_disc"   "0.0000"
row "other"     "$pz_other"  "$ps_other"
printf "$FMT" "$(dashes $LW)" "$(dashes $PW)" "$(dashes $SW)" "$(dashes $PW)" "$(dashes $SW)" \
    "$(dashes $RW)" "$(dashes $PSW)" "$(dashes $PRW)"
row "total"     "100.0000"   "100.0000"  "$primal_total"
