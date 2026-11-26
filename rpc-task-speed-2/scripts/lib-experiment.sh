#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# The SDK experiment (sdk-monitor-nlr.patch applied in the worktree): host
# SDK, f1 and f2 firmwares with suffix lib, their bench and perf envelopes
# (snapshots compiled by the patched SDK into env/snap-$S-f*), one C6
# session each. The caller reverts the patch afterwards.
set -uo pipefail
S=${1:-lib}
A=/home/flo/work/opentoit-sandbox-artifacts/rpc-task-speed-2
bash "$A/scripts/sdk.sh" > "$A/logs/sdk-$S.log" 2>&1 || { echo "sdk failed"; exit 1; }
JOBS=8 SUFFIX=$S bash "$A/scripts/fw-all.sh" esp32c6 $S f1 f2
# Keep the patched snapshots apart from the unpatched ones.
for f in 1 2; do
  [ -d "$A/env/snap-f$f" ] && cp -r "$A/env/snap-f$f" "$A/env/snap-f$f.keep"
done
for c in f1-$S f2-$S; do
  bash "$A/scripts/mkenvs.sh" esp32c6 "$c" bench perf
done
for f in 1 2; do
  rm -rf "$A/env/snap-$S-f$f"; cp -r "$A/env/snap-f$f" "$A/env/snap-$S-f$f"
  rm -rf "$A/env/snap-f$f"; mv "$A/env/snap-f$f.keep" "$A/env/snap-f$f"
done
bash "$A/scripts/session.sh" c6 esp32c6 r1 f1-$S f2-$S
