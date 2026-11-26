#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Reruns the instruction counts (they failed while the host SDK was rebuilt).
set -u
S=/home/flo/work/opentoit-sandbox-artifacts/ec618/scripts
A=/home/flo/work/opentoit-sandbox-artifacts/ec618
for c in "f2 build/ec618-f2 2" "f2s build/ec618-f2s 2" "f2z build/ec618-f2z 2" "f2cxx build/ec618-f2cxx 2" "f1 build/ec618 1"; do
  read -r n b f <<< "$c"
  bash "$S/insn-bench.sh" "$n" "$b" "$f" > /dev/null || echo "$n failed"
done
bash "$S/insn-install.sh" f2 build/ec618-f2 > "$A/qemu/install-f2.txt"
bash "$S/insn-install.sh" f2s build/ec618-f2s > "$A/qemu/install-f2s.txt"
echo done
