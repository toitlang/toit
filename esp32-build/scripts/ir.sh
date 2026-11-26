#!/usr/bin/env bash
# Instructions inside the interpreters (callgrind --toggle-collect of
# toit::Interpreter::run for format 1, toit_v2_run for format 2; callees
# included; startup and launch verification excluded). Format 2 with
# TOIT_VERIFY=1 (the verified loop). Same method as core-size/ir.sh.
# Usage: ir.sh LABEL TOIT.RUN f1|f2
A=/home/flo/work/opentoit-sandbox-artifacts/esp32-build
label=$1; bin=$2; fmt=$3; shift 3
OUT=$A/ir
mkdir -p "$OUT/cg"
if [ "$fmt" = f1 ]; then fn='toit::Interpreter::run()'; v=""; else fn=toit_v2_run; v=1; fi
for b in richards deltablue pystone; do
  (
    f="$OUT/cg/cg.$label.$b"
    rm -f "$f".*
    env TOIT_VERIFY=$v "$@" valgrind --tool=callgrind "--toggle-collect=$fn" --callgrind-out-file="$f.%p" \
      "$bin" "$A/snap/$b-$fmt.snap" > "$f.out" 2>&1
    ir=$(cat "$f".[0-9]* | awk '/^summary:/ { s += $2 } END { print s + 0 }')
    echo "$label $b $ir"
  ) &
done | sort | tee -a "$OUT/results.txt"
wait
