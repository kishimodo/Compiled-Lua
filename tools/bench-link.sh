#!/usr/bin/env bash
# bench-link.sh <clua.exe> <script.lua> <runs> [opt-level]
# Prints per-run milliseconds plus min/median/max for warm repeated builds.
set -u
EXE="$1"; SRC="$2"; RUNS="${3:-9}"; OPT="${4:--O1}"
OUT="${TMPDIR:-/tmp}/bench_out_$$.exe"
times=()
# one warm-up run (page cache / OneDrive rehydrate) that is not measured
"$EXE" build "$SRC" "$OPT" -o "$OUT" >/dev/null 2>&1 || { echo "warmup FAILED"; exit 1; }
for i in $(seq 1 "$RUNS"); do
  s=$(date +%s%N)
  "$EXE" build "$SRC" "$OPT" -o "$OUT" >/dev/null 2>&1 || { echo "run $i FAILED"; exit 1; }
  e=$(date +%s%N)
  times+=( $(( (e - s) / 1000000 )) )
done
rm -f "$OUT"
printf 'runs:'; printf ' %s' "${times[@]}"; printf '\n'
sorted=$(printf '%s\n' "${times[@]}" | sort -n)
n=${#times[@]}
mid=$(( n / 2 ))
median=$(printf '%s\n' "$sorted" | sed -n "$((mid+1))p")
if (( n % 2 == 0 )); then
  a=$(printf '%s\n' "$sorted" | sed -n "${mid}p")
  median=$(( (a + median) / 2 ))
fi
echo "min=$(printf '%s\n' "$sorted" | head -1)ms median=${median}ms max=$(printf '%s\n' "$sorted" | tail -1)ms n=$n"
