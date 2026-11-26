#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# s3-ota-soak's firmware builds, one after the other (fw.sh builds from one
# copy of the worktree, build/fwsrc).
#   STAGE=1: ESP32-S3 f2, f1, f2time (defaults: PSRAM enabled with
#            SPIRAM_IGNORE_NOTFOUND, as upstream), C6 f2, f1.
#   STAGE=2: the OTA targets (PAD=2400 rebuilds: the same code shifted, a
#            different binary with the same SDK version).
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/s3-ota-soak
cd "$A" || exit 1
have() { [ -f "bins/$1/sections.txt" ]; }
if [ "${STAGE:-1}" = 1 ]; then
  for c in f2 f1 f2time; do have esp32s3-$c || bash scripts/fw-all.sh esp32s3 s3 $c; done
  for c in f2 f1; do have esp32c6-$c || bash scripts/fw-all.sh esp32c6 s3 $c; done
fi
if [ "${STAGE:-1}" = 2 ]; then
  for c in f2 f1; do have esp32c6-$c-p2400 || PAD=2400 bash scripts/fw-all.sh esp32c6 s3 $c; done
  for c in f2; do have esp32s3-$c-p2400 || PAD=2400 bash scripts/fw-all.sh esp32s3 s3 $c; done
fi
echo "queue stage ${STAGE:-1} done"
