#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

# Optional host firmware integration test. No radio or Python is used.
set -euo pipefail
if [[ $# != 3 && $# != 4 ]]; then
  echo "Usage: $0 TOIT HOST_ENVELOPE NEW_OUTPUT_DIRECTORY [provider|client]" >&2
  exit 2
fi
mode=${4:-provider}
if [[ $mode != provider && $mode != client ]]; then
  echo "Expected provider or client OOM mode" >&2
  exit 2
fi
toit=$(realpath -- "$1")
base=$(realpath -- "$2")
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
mkdir -- "$3"
output=$(realpath -- "$3")
for role in provider client; do
  "$toit" compile --project-root "$repo/tests" -s -o "$output/$role.snapshot" \
    "$repo/tests/ble-hardware/$mode-oom-$role.toit"
done
# The dying container must be bundled without a boot trigger. Its coordinator
# checks the flags and starts it explicitly; host startup images are critical.
coordinator=client
if [[ $mode == client ]]; then coordinator=provider; fi
"$toit" tool firmware -e "$base" container install --trigger=none \
  -o "$output/firmware.envelope" ble-oom-peer "$output/$mode.snapshot"
"$toit" tool firmware -e "$output/firmware.envelope" container install \
  ble-oom-main "$output/$coordinator.snapshot"
"$toit" tool firmware -e "$output/firmware.envelope" extract --format=tar -o "$output/run.tar"
mkdir "$output/run"
tar -xf "$output/run.tar" -C "$output/run"
mkdir "$output/run/scratch"
export TOIT_CONFIG_DATA="$output/run/ota0/config.ubjson"
export TOIT_FLASH_UUID_FILE="$output/run/ota0/uuid"
export TOIT_FLASH_REGISTRY_FILE="$output/run/flash-registry"
# Avoid boot.sh's automatic restart and flash-registry recovery behavior.
status=0
timeout --signal=TERM --kill-after=1s 15s "$output/run/ota0/run-image" \
  "$output/run/ota0" "$output/run/scratch" > "$output/run.log" 2>&1 || status=$?
echo "$status" > "$output/run.exit"
sha256sum "$toit" "$base" "$output/provider.snapshot" "$output/client.snapshot" \
  "$output/run/ota0/run-image" "$output/run.log" \
  "$repo/tests/ble-service-provider-restart-test.toit" \
  "$repo/tests/ble-service-multiclient-exit-test.toit" \
  "$repo/system/extensions/host/run-image.toit" \
  "$repo/tests/ble-hardware/$mode-oom-provider.toit" \
  "$repo/tests/ble-hardware/$mode-oom-client.toit" \
  "$repo/tests/ble-hardware/provider-oom-host.sh" > "$output/sha256.txt"
cat "$output/run.log"
if [[ $status != 0 ]]; then exit "$status"; fi
checkpoints=(
  'BLE_PROVIDER_RESTART COMPLETE oom=true waiters=2 stale-handles=invalid replacement-read=43' \
  'BLE_PROVIDER_OOM COMPLETE non-critical=true provider-exit=1'
)
if [[ $mode == client ]]; then
  checkpoints=('BLE_CLIENT_OOM COMPLETE non-critical=true client-exit=1 subscription-released=true survivor-reads=2 slot-reused=true controller-opens=1')
fi
for checkpoint in "${checkpoints[@]}"; do
  if [[ $(grep -Fxc -- "$checkpoint" "$output/run.log") != 1 ]]; then
    echo "Missing or duplicate OOM recovery checkpoint" >&2
    exit 1
  fi
done
echo "OOM_HOST COMPLETE mode=$mode hardware=false artifacts=$output"
