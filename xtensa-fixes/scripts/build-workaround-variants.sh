#!/usr/bin/env bash
# Device library variants for the workaround costs (exposure.sh then
# compares them): the DAG combiner disabled (avoids llvm#139 entirely) at
# opt 3 and z.
set -euo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a13f01ee86eed5211
S=/home/flo/work/opentoit-sandbox-artifacts/xtensa-fixes/scripts/build-devlib.sh
OPT=3 bash "$S" "$WT" o3-nocombine -C llvm-args=-combiner-disabled
OPT=z bash "$S" "$WT" oz-nocombine -C llvm-args=-combiner-disabled
OPT=3 LTO=1 bash "$S" "$WT" o3-lto-nocombine -C llvm-args=-combiner-disabled
