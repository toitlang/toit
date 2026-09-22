#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

# Optional Linux firmware/storage integration test. No radio or Python is used.
set -euo pipefail
if [[ $# != 3 ]]; then
  echo "Usage: $0 TOIT HOST_ENVELOPE NEW_OUTPUT_DIRECTORY" >&2
  exit 2
fi
toit=$(realpath -- "$1")
base=$(realpath -- "$2")
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
mkdir -- "$3"
output=$(realpath -- "$3")

"$toit" compile --project-root "$repo/tests" -s -o "$output/restart.snapshot" \
  "$repo/tests/ble-hardware/revocation-restart.toit"
"$toit" tool firmware -e "$base" container install -o "$output/firmware.envelope" \
  ble-revoke "$output/restart.snapshot"
"$toit" tool firmware -e "$output/firmware.envelope" extract --format=tar -o "$output/run.tar"
mkdir "$output/run"
tar -xf "$output/run.tar" -C "$output/run"
mkdir "$output/run/scratch"

# Invoke the runtime directly: boot.sh automatically restarts firmware and can
# erase the flash registry after a crash, which would invalidate this test.
export TOIT_CONFIG_DATA="$output/run/ota0/config.ubjson"
export TOIT_FLASH_UUID_FILE="$output/run/ota0/uuid"
export TOIT_FLASH_REGISTRY_FILE="$output/run/flash-registry"
for phase in 1 2 3; do
  if timeout --signal=TERM --kill-after=1s 10s "$output/run/ota0/run-image" \
      "$output/run/ota0" "$output/run/scratch" > "$output/boot-$phase.log" 2>&1; then
    echo 0 > "$output/boot-$phase.exit"
  else
    status=$?
    echo "$status" > "$output/boot-$phase.exit"
    cat "$output/boot-$phase.log" >&2
    exit "$status"
  fi
  expected="BOND_REVOCATION_RESTART READY phase=$phase reset-required=true"
  if [[ $phase == 3 ]]; then expected="BOND_REVOCATION_RESTART COMPLETE phases=3"; fi
  if [[ $(<"$output/boot-$phase.log") != "$expected" ]]; then
    cat "$output/boot-$phase.log" >&2
    echo "Unexpected restart checkpoint at phase $phase" >&2
    exit 1
  fi
done
sha256sum "$toit" "$base" "$repo/tests/ble-hardware/revocation-restart.toit" \
  "$repo/lib/ble/experimental/bond-revocation.toit" "$output/restart.snapshot" \
  "$output/run/ota0/run-image" "$output/run/flash-registry" \
  "$output/boot-1.log" "$output/boot-2.log" "$output/boot-3.log" > "$output/sha256.txt"
echo "REVOCATION_RESTART_HOST COMPLETE boots=3 hardware=false artifacts=$output"
