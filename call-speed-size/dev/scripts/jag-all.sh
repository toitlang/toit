#!/usr/bin/env bash
# Compiles Jaguar (f1, f2) with build/host-dev and runs jag-check.sh for
# the ESP32 and C6 in f1 and f2. Output: dev/jag-all.txt
D=/home/flo/work/opentoit-sandbox-artifacts/call-speed-size/dev
T=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a61139585de4882bc/build/host/sdk/bin/toit
cd "$D" || exit 1
TOIT_BYTECODE_FORMAT=1 "$T" compile -O2 --snapshot --project-root /home/flo/work/jaguar -o jaguar/jaguar-f1.snapshot /home/flo/work/jaguar/src/jaguar.toit || exit 1
TOIT_BYTECODE_FORMAT=2 "$T" compile -O2 --snapshot --project-root /home/flo/work/jaguar -o jaguar/jaguar-f2.snapshot /home/flo/work/jaguar/src/jaguar.toit || exit 1
for f in f1 f2; do
  "$T" tool snapshot-to-image -m32 --format=binary -o "jaguar/jaguar-$f.image" "jaguar/jaguar-$f.snapshot"
  echo "jaguar-$f image $(stat -c %s "jaguar/jaguar-$f.image")"
done | tee jag-all.txt
for t in esp32 esp32c6; do
  for c in f1 f2; do
    bash scripts/jag-check.sh "$t" "$c" 2>&1 | tail -2
  done
done | tee -a jag-all.txt
