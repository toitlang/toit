#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# After the harness links libgcc/newlib before the Rust archive: rebuild the
# harnesses, rerun the suites and instruction counts, and the primitive
# differential (8 seeds x 250,000 calls, f1 against f2) in parallel.
set -u
S=/home/flo/work/opentoit-sandbox-artifacts/ec618/scripts
A=/home/flo/work/opentoit-sandbox-artifacts/ec618
bash "$S/harness-build.sh" build/ec618 build/ec618-f2 build/ec618-f2s build/ec618-f2z build/ec618-f2cxx 2>&1 | grep -v -i 'cmake\|warning\|policy\|version\|update\|project\|behavior\|^$\|manual\|specific\|Wno'
for s in 1 2 3 4 5 6 7 8; do
  bash "$S/prim-diff.sh" 250000 "$s" > "$A/qemu/prim-diff/result-$s.txt" 2>&1 &
done
bash "$S/qrun.sh" "$A/qemu/run-f2-final.txt" build/ec618-f2 "$A/qemu/env/f2-suite.envelope"
bash "$S/qrun.sh" "$A/qemu/run-f1-final.txt" build/ec618 "$A/qemu/env/f1-suite.envelope"
for c in "f1 build/ec618 1" "f2 build/ec618-f2 2" "f2s build/ec618-f2s 2" "f2z build/ec618-f2z 2" "f2cxx build/ec618-f2cxx 2"; do
  read -r n b f <<< "$c"
  bash "$S/insn-bench.sh" "$n" "$b" "$f" > /dev/null
done
bash "$S/insn-install.sh" f2 build/ec618-f2 > "$A/qemu/install-f2.txt"
bash "$S/insn-install.sh" f2s build/ec618-f2s > "$A/qemu/install-f2s.txt"
wait
cat "$A"/qemu/prim-diff/result-*.txt
echo done
