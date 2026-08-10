#!/usr/bin/env bash

# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
QEMU_SYSTEM_XTENSA="${QEMU_SYSTEM_XTENSA:-qemu-system-xtensa}"
TOIT="${TOIT:-${ROOT_DIR}/build/host/sdk/bin/toit}"
UART_ENVELOPE="${UART_ENVELOPE:-${ROOT_DIR}/build/esp32/firmware.envelope}"
USB_ENVELOPE="${USB_ENVELOPE:-${ROOT_DIR}/build/esp32s3-usj/firmware.envelope}"
QEMU_TIMEOUT_TICKS="${QEMU_TIMEOUT_TICKS:-300}"

if ! command -v "${QEMU_SYSTEM_XTENSA}" >/dev/null 2>&1; then
  echo "QEMU executable not found: ${QEMU_SYSTEM_XTENSA}" >&2
  exit 2
fi
if [[ ! -x "${TOIT}" ]]; then
  echo "Toit executable is not executable: ${TOIT}" >&2
  exit 2
fi
for envelope in "${UART_ENVELOPE}" "${USB_ENVELOPE}"; do
  if [[ ! -f "${envelope}" ]]; then
    echo "Firmware envelope not found: ${envelope}" >&2
    exit 2
  fi
done

TEMP_DIR="$(mktemp -d)"
QEMU_PID=""
QEMU_LOG=""
SERIAL_PORT=""

stop_qemu() {
  exec 3>&- || true
  if [[ -n "${QEMU_PID}" ]]; then
    kill "${QEMU_PID}" 2>/dev/null || true
    wait "${QEMU_PID}" 2>/dev/null || true
    QEMU_PID=""
  fi
}

cleanup() {
  stop_qemu
  rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT

make_image() {
  local fixture="$1"
  local envelope="$2"
  local name="$3"
  local source="${TEMP_DIR}/${fixture}"

  cp "${ROOT_DIR}/tests/qemu/${fixture}" "${source}"
  "${TOIT}" compile --snapshot --project-root "${TEMP_DIR}" \
    -o "${TEMP_DIR}/${name}.snapshot" \
    "${source}"
  "${TOIT}" tool firmware --envelope="${envelope}" container install \
    -o "${TEMP_DIR}/${name}.envelope" \
    "${name}" "${TEMP_DIR}/${name}.snapshot"
  "${TOIT}" tool firmware --envelope="${TEMP_DIR}/${name}.envelope" extract \
    --format=image -o "${TEMP_DIR}/${name}.bin"
}

start_qemu() {
  local machine="$1"
  local image="$2"
  local console="$3"
  local input="${TEMP_DIR}/${image}.in"
  QEMU_LOG="${TEMP_DIR}/${image}.log"

  mkfifo "${input}"
  exec 3<>"${input}"

  local -a console_options
  if [[ "${console}" == uart ]]; then
    console_options=(-serial stdio)
  else
    console_options=(
      -serial null
      -chardev stdio,id=usb
      -global driver=misc.esp32c3.usb_serial_jtag,property=chardev,value=usb
    )
  fi

  "${QEMU_SYSTEM_XTENSA}" \
    -M "${machine}" \
    -accel tcg,thread=single \
    -display none \
    -monitor none \
    -no-reboot \
    -drive "file=${TEMP_DIR}/${image}.bin,if=mtd,format=raw" \
    "${console_options[@]}" \
    <"${input}" >"${QEMU_LOG}" 2>&1 &
  QEMU_PID="$!"
}

start_qemu_download_mode() {
  local image="$1"
  QEMU_LOG="${TEMP_DIR}/${image}-download.log"

  "${QEMU_SYSTEM_XTENSA}" \
    -M esp32 \
    -accel tcg,thread=single \
    -global driver=esp32.gpio,property=strap_mode,value=15 \
    -display none \
    -monitor none \
    -no-reboot \
    -serial pty \
    -drive "file=${TEMP_DIR}/${image}.bin,if=mtd,format=raw" \
    >"${QEMU_LOG}" 2>&1 &
  QEMU_PID="$!"
}

wait_for_serial_port() {
  SERIAL_PORT=""
  for ((tick = 0; tick < QEMU_TIMEOUT_TICKS; tick++)); do
    SERIAL_PORT="$(awk '/char device redirected to/ { print $5; exit }' "${QEMU_LOG}")"
    if [[ -n "${SERIAL_PORT}" ]]; then
      return 0
    fi
    if ! kill -0 "${QEMU_PID}" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done

  echo "Timed out waiting for QEMU's serial port." >&2
  cat "${QEMU_LOG}" >&2
  return 1
}

wait_for() {
  local marker="$1"
  for ((tick = 0; tick < QEMU_TIMEOUT_TICKS; tick++)); do
    if grep -Fq "${marker}" "${QEMU_LOG}"; then
      return 0
    fi
    if ! kill -0 "${QEMU_PID}" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done

  echo "Timed out waiting for '${marker}'." >&2
  cat "${QEMU_LOG}" >&2
  return 1
}

run_stdio_test() {
  local machine="$1"
  local image="$2"
  local console="$3"

  start_qemu "${machine}" "${image}" "${console}"
  wait_for STDIO-READY
  printf 'hello-qemu\n' >&3
  wait_for STDOUT:hello-qemu
  wait_for STDERR:hello-qemu
  stop_qemu
  echo "PASS: ${machine} ${console} stdin/stdout/stderr"
}

run_esptool_flash_test() {
  local image=esptool-flashed
  local image_size
  image_size="$(stat --format=%s "${TEMP_DIR}/stdio-uart.bin")"
  truncate --size="${image_size}" "${TEMP_DIR}/${image}.bin"

  start_qemu_download_mode "${image}"
  wait_for_serial_port
  "${TOIT}" tool firmware \
    --envelope="${TEMP_DIR}/stdio-uart.envelope" \
    flash --port="${SERIAL_PORT}"
  stop_qemu

  start_qemu esp32 "${image}" uart
  wait_for STDIO-READY
  printf 'hello-flashed-qemu\n' >&3
  wait_for STDOUT:hello-flashed-qemu
  wait_for STDERR:hello-flashed-qemu
  stop_qemu
  echo "PASS: bundled esptool flashed and booted an ESP32 in QEMU"
}

run_uart_sharing_test() {
  start_qemu esp32 uart-share uart
  wait_for IO-READY
  printf 'io-line\n' >&3
  wait_for IO:io-line
  wait_for UART-READY
  printf 'uart-line\n' >&3
  wait_for UART:uart-line
  stop_qemu
  echo "PASS: ESP32 io.stdin and uart.Port.console sharing"
}

make_image stdio.toit "${UART_ENVELOPE}" stdio-uart
make_image stdio-uart-console.toit "${UART_ENVELOPE}" uart-share
make_image stdio.toit "${USB_ENVELOPE}" stdio-usb

run_esptool_flash_test
run_stdio_test esp32 stdio-uart uart
run_uart_sharing_test
run_stdio_test esp32s3 stdio-usb usb-serial-jtag
