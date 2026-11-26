#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# The primitive differential, 8 seeds x 250,000 calls in parallel.
set -u
S=/home/flo/work/opentoit-sandbox-artifacts/ec618/scripts
A=/home/flo/work/opentoit-sandbox-artifacts/ec618
for s in 1 2 3 4 5 6 7 8; do
  bash "$S/prim-diff.sh" 250000 "$s" > "$A/qemu/prim-diff/result-$s.txt" 2>&1 &
done
wait
cat "$A"/qemu/prim-diff/result-*.txt
