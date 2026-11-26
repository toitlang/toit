#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Harness builds and instruction counts of the opt-level s/z and f2cxx configurations.
set -euo pipefail
S=/home/flo/work/opentoit-sandbox-artifacts/ec618/scripts
bash "$S/harness-build.sh" build/ec618-f2s build/ec618-f2z build/ec618-f2cxx
bash "$S/insn-bench.sh" f2s build/ec618-f2s 2
bash "$S/insn-bench.sh" f2z build/ec618-f2z 2
bash "$S/insn-bench.sh" f2cxx build/ec618-f2cxx 2
echo done
