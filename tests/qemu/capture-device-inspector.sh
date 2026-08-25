#!/usr/bin/env bash

# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

set -euo pipefail

if [[ "$#" -ne 5 && "$#" -ne 6 && "$#" -ne 7 ]]; then
  echo "Usage: $0 QEMU MACHINE FLASH.bin MANIFEST.json OUTPUT.toitdump [CHECKPOINT [PROCESS_GROUP_ID]]" >&2
  exit 2
fi

QEMU="$1"
MACHINE="$2"
FLASH_IMAGE="$3"
MANIFEST="$4"
OUTPUT="$5"
CHECKPOINT="${6:-}"
PROCESS_GROUP_ID="${7:-}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOIT="${TOIT:-${ROOT_DIR}/build/host/sdk/bin/toit}"
READY_MARKER="${READY_MARKER:-DEVICE-INSPECTOR-READY}"
TIMEOUT_TICKS="${QEMU_TIMEOUT_TICKS:-300}"
PSRAM_SIZE="${QEMU_PSRAM_SIZE:-}"
PSRAM_MODE="${QEMU_PSRAM_MODE:-quad}"

for executable in "${QEMU}" "${TOIT}"; do
  if [[ ! -x "${executable}" ]]; then
    echo "Executable not found: ${executable}" >&2
    exit 2
  fi
done
for input in "${FLASH_IMAGE}" "${MANIFEST}"; do
  if [[ ! -f "${input}" ]]; then
    echo "Input not found: ${input}" >&2
    exit 2
  fi
done

MANIFEST_DIR="$(cd "$(dirname "${MANIFEST}")" && pwd)"
MANIFEST_ABS="${MANIFEST_DIR}/$(basename "${MANIFEST}")"
TEMP_DIR="$(mktemp -d)"
QEMU_LOG="${TEMP_DIR}/qemu.log"
UART_LOG="${TEMP_DIR}/uart.log"
PORT_BASE="${QEMU_INSPECTOR_PORT_BASE:-$((20000 + ($$ % 19000) * 2))}"
QMP_PORT="${PORT_BASE}"
GDB_PORT="$((PORT_BASE + 1))"
RESOLVED_MANIFEST="${MANIFEST_DIR}/qemu-resolved-manifest.json"
CHECKPOINT_LAYOUT="${MANIFEST_DIR}/checkpoint-layout.json"
QEMU_PID=""

QEMU_START_ARGS=()
ACQUIRE_ARGS=()
if [[ -n "${PSRAM_SIZE}" ]]; then
  case "${MACHINE}:${PSRAM_SIZE}" in
    esp32:2M|esp32:4M|esp32s3:2M|esp32s3:4M|esp32s3:8M|esp32s3:16M|esp32s3:32M)
      ;;
    esp32:*)
      echo "Classic ESP32 QEMU supports QEMU_PSRAM_SIZE=2M or 4M." >&2
      exit 2
      ;;
    esp32s3:*)
      echo "ESP32-S3 QEMU supports QEMU_PSRAM_SIZE=2M, 4M, 8M, 16M, or 32M." >&2
      exit 2
      ;;
    *)
      echo "QEMU_PSRAM_SIZE is not supported for machine '${MACHINE}' by this wrapper." >&2
      exit 2
      ;;
  esac
  QEMU_START_ARGS+=("-m" "${PSRAM_SIZE}")
  case "${MACHINE}:${PSRAM_MODE}" in
    esp32:quad|esp32s3:quad)
      ;;
    esp32s3:octal)
      QEMU_START_ARGS+=("-global" "driver=ssi_psram,property=is_octal,value=true")
      ;;
    esp32:octal)
      echo "Classic ESP32 QEMU does not support octal PSRAM." >&2
      exit 2
      ;;
    *)
      echo "QEMU_PSRAM_MODE must be 'quad' or 'octal'." >&2
      exit 2
      ;;
  esac
elif [[ "${PSRAM_MODE}" != "quad" ]]; then
  echo "QEMU_PSRAM_MODE requires QEMU_PSRAM_SIZE." >&2
  exit 2
fi
if [[ -n "${CHECKPOINT}" ]]; then
  if [[ ! -f "${CHECKPOINT_LAYOUT}" ]]; then
    echo "Checkpoint layout not found: ${CHECKPOINT_LAYOUT}" >&2
    exit 2
  fi
  QEMU_START_ARGS+=("-S")
  ACQUIRE_ARGS+=("${CHECKPOINT_LAYOUT}" "${CHECKPOINT}")
fi
if [[ -n "${PROCESS_GROUP_ID}" ]]; then
  ACQUIRE_ARGS+=("${PROCESS_GROUP_ID}")
fi

cleanup() {
  if [[ -n "${QEMU_PID}" ]]; then
    kill "${QEMU_PID}" 2>/dev/null || true
    wait "${QEMU_PID}" 2>/dev/null || true
  fi
  rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT

: >"${UART_LOG}"
"${QEMU}" \
  "${QEMU_START_ARGS[@]}" \
  -M "${MACHINE}" \
  -accel tcg,thread=single \
  -display none \
  -no-reboot \
  -serial "file:${UART_LOG}" \
  -monitor none \
  -qmp "tcp:127.0.0.1:${QMP_PORT},server=on,wait=off" \
  -gdb "tcp:127.0.0.1:${GDB_PORT},server=on,wait=off" \
  -drive "file=${FLASH_IMAGE},if=mtd,format=raw" \
  >"${QEMU_LOG}" 2>&1 &
QEMU_PID="$!"

if [[ -z "${CHECKPOINT}" ]]; then
  ready=false
  for ((tick = 0; tick < TIMEOUT_TICKS; tick++)); do
    if grep -Fq "${READY_MARKER}" "${UART_LOG}"; then
      ready=true
      break
    fi
    if ! kill -0 "${QEMU_PID}" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
  if [[ "${ready}" != true ]]; then
    echo "QEMU did not reach '${READY_MARKER}'." >&2
    cat "${UART_LOG}" >&2
    cat "${QEMU_LOG}" >&2
    exit 1
  fi
fi

if ! "${TOIT}" run --project-root "${ROOT_DIR}/tools" \
    "${ROOT_DIR}/tools/device-inspector/qemu-acquire.toit" -- \
    "${QMP_PORT}" \
    "${GDB_PORT}" \
    "${MANIFEST_ABS}" \
    "${RESOLVED_MANIFEST}" \
    "${ACQUIRE_ARGS[@]}"; then
  cat "${QEMU_LOG}" >&2
  exit 1
fi
wait "${QEMU_PID}"
QEMU_PID=""

"${TOIT}" run --project-root "${ROOT_DIR}/tools" \
  "${ROOT_DIR}/tools/device-inspector/device-inspector.toit" -- \
  import "${RESOLVED_MANIFEST}" "${OUTPUT}"
