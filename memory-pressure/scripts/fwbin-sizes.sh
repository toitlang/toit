#!/usr/bin/env bash
# Size of the flashed firmware binary (toit.bin with the system image and
# the config in its DROM extension) of each envelope in bins/.
# Usage: fwbin-sizes.sh TARGET [CONFIGS...]
set -uo pipefail
WT=${WT:-/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a2ae466cd9dbd080f}
A=/home/flo/work/opentoit-sandbox-artifacts/memory-pressure
TARGET=$1
shift
for c in ${*:-f1 f2cxx f2}; do
  D=$A/bins/$TARGET-$c
  "$WT/build/host/sdk/bin/toit" tool firmware -e "$D/firmware.envelope" extract --format binary -o "$D/firmware.bin" > /dev/null
  echo "$TARGET-$c firmware.bin $(stat -c %s "$D/firmware.bin")"
done
