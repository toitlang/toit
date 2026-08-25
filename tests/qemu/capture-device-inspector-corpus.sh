#!/usr/bin/env bash

# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

set -euo pipefail

if [[ "$#" -ne 5 ]]; then
  echo "Usage: $0 QEMU MACHINE FLASH.bin TEMPLATE_DIR OUTPUT_DIR" >&2
  exit 2
fi

QEMU="$1"
MACHINE="$2"
FLASH_IMAGE="$3"
TEMPLATE_DIR="$(cd "$4" && pwd)"
OUTPUT_DIR="$5"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOIT="${TOIT:-${ROOT_DIR}/build/host/sdk/bin/toit}"

mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR="$(cd "${OUTPUT_DIR}" && pwd)"
CHECKPOINT_TIMEOUT_SECONDS="${CHECKPOINT_TIMEOUT_SECONDS:-90}"

CHECKPOINTS=(
  mutator-armed
  scavenge-started
  scavenge-after-forwarding
  scavenge-after-roots
  scavenge-complete
  mark-after-roots
  mark-complete
  sweep-started
  compaction-started
  gc-complete
)
FIXTURE_FILES=(
  manifest.json
  checkpoint-layout.json
  runtime-layout.json
  system-program-layout.json
  program-layout.json
  system.snapshot
  firmware.elf
  device-inspector.envelope
  device-inspector.snapshot
)

for file in "${FIXTURE_FILES[@]}"; do
  if [[ ! -f "${TEMPLATE_DIR}/${file}" ]]; then
    echo "Fixture file not found: ${TEMPLATE_DIR}/${file}" >&2
    exit 2
  fi
done

for checkpoint in "${CHECKPOINTS[@]}"; do
  capture_dir="${OUTPUT_DIR}/${checkpoint}"
  mkdir -p "${capture_dir}"
  for file in "${FIXTURE_FILES[@]}"; do
    if [[ ! -e "${capture_dir}/${file}" ]]; then
      ln -s "${TEMPLATE_DIR}/${file}" "${capture_dir}/${file}"
    fi
  done
  if [[ -f "${capture_dir}/device.toitdump" ]]; then
    echo "Checkpoint already captured: ${checkpoint}"
    continue
  fi
  timeout --foreground "${CHECKPOINT_TIMEOUT_SECONDS}s" env \
    QEMU_PSRAM_SIZE="${QEMU_PSRAM_SIZE:-4M}" \
    QEMU_PSRAM_MODE="${QEMU_PSRAM_MODE:-octal}" \
    "${ROOT_DIR}/tests/qemu/capture-device-inspector.sh" \
    "${QEMU}" "${MACHINE}" "${FLASH_IMAGE}" \
    "${capture_dir}/manifest.json" "${capture_dir}/device.toitdump" \
    "${checkpoint}"
done

"${TOIT}" run --project-root "${ROOT_DIR}/tools" \
  "${ROOT_DIR}/tools/device-inspector/verify-checkpoint-corpus.toit" -- \
  "${OUTPUT_DIR}"
