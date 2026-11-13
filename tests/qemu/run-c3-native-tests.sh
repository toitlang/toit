#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

# Boots ESP32-C3 firmware in QEMU in all the ways the firmware tool can
# extract it: as it is, with the containers combined with the system program,
# compiled to native code, and both. The envelope must have native support
# ('make esp32c3 ESP32_NATIVE_SUPPORT=1'), and native extraction needs the
# ESP-IDF tools (esp-clang and the RISC-V toolchain).
#
# QEMU must not be given an eFuse file. The eFuses that QEMU has by default
# have the ADC calibration, so ESP-IDF doesn't calibrate the ADC at startup,
# which QEMU doesn't emulate.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
QEMU_SYSTEM_RISCV32="${QEMU_SYSTEM_RISCV32:-qemu-system-riscv32}"
TOIT="${TOIT:-${ROOT_DIR}/build/host/sdk/bin/toit}"
ENVELOPE="${ENVELOPE:-${ROOT_DIR}/build/esp32c3/firmware.envelope}"
QEMU_TIMEOUT_TICKS="${QEMU_TIMEOUT_TICKS:-600}"

if ! command -v "${QEMU_SYSTEM_RISCV32}" >/dev/null 2>&1; then
  echo "QEMU executable not found: ${QEMU_SYSTEM_RISCV32}" >&2
  exit 2
fi
if [[ ! -f "${ENVELOPE}" ]]; then
  echo "Firmware envelope not found: ${ENVELOPE}" >&2
  exit 2
fi

TEMP_DIR="$(mktemp -d)"
QEMU_PID=""

stop_qemu() {
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

# Two containers that are installed from source, so they can be combined and
# compiled to native code, and one that runs a snapshot, which always runs
# its bytecodes.
mkdir -p "${TEMP_DIR}/app"
touch "${TEMP_DIR}/app/package.yaml"
cat > "${TEMP_DIR}/app/first.toit" <<'EOF'
fib n/int -> int: return n < 2 ? n : (fib n - 1) + (fib n - 2)
main: print "TOIT-QEMU-FIRST: $(fib 20)"
EOF
cat > "${TEMP_DIR}/app/second.toit" <<'EOF'
main:
  // Doubles and integers that don't fit in a small integer go through the
  // runtime of native code.
  sum := 0.0
  10.repeat: sum += it * 0.5
  big := 1
  62.repeat: big *= 2
  print "TOIT-QEMU-SECOND: $(List 10: it * it) $sum $(1.5 * 2.25) $(1 << 62) $(big >> 52)"
EOF
cat > "${TEMP_DIR}/app/snapshot.toit" <<'EOF'
main: print "TOIT-QEMU-SNAPSHOT"
EOF
"${TOIT}" compile --snapshot -o "${TEMP_DIR}/snapshot.snapshot" "${TEMP_DIR}/app/snapshot.toit"

ENVELOPE_WITH_CONTAINERS="${TEMP_DIR}/containers.envelope"
"${TOIT}" tool firmware -e "${ENVELOPE}" container install \
    -o "${ENVELOPE_WITH_CONTAINERS}" first "${TEMP_DIR}/app/first.toit"
"${TOIT}" tool firmware -e "${ENVELOPE_WITH_CONTAINERS}" container install \
    second "${TEMP_DIR}/app/second.toit"
"${TOIT}" tool firmware -e "${ENVELOPE_WITH_CONTAINERS}" container install \
    snapshot "${TEMP_DIR}/snapshot.snapshot"

EXPECTED=(
  "TOIT-QEMU-FIRST: 6765"
  "TOIT-QEMU-SECOND: [0, 1, 4, 9, 16, 25, 36, 49, 64, 81] 22.5 3.375 4611686018427387904 1024"
  "TOIT-QEMU-SNAPSHOT"
)

run_mode() {
  local mode="$1"
  shift
  local image="${TEMP_DIR}/${mode}.bin"
  local log="${TEMP_DIR}/${mode}.log"
  echo "=== ${mode}"
  "${TOIT}" tool firmware -e "${ENVELOPE_WITH_CONTAINERS}" extract "$@" \
      --format=image -o "${image}"
  "${QEMU_SYSTEM_RISCV32}" \
    -M esp32c3 \
    -accel tcg,thread=single \
    -nographic \
    -no-reboot \
    -drive "file=${image},if=mtd,format=raw" \
    -global driver=timer.esp32c3.timg,property=wdt_disable,value=true \
    > "${log}" 2>&1 &
  QEMU_PID="$!"
  local found
  for ((tick = 0; tick < QEMU_TIMEOUT_TICKS; tick++)); do
    found=0
    for line in "${EXPECTED[@]}"; do
      if grep -qF "${line}" "${log}"; then found=$((found + 1)); fi
    done
    if [[ ${found} -eq ${#EXPECTED[@]} ]]; then break; fi
    if ! kill -0 "${QEMU_PID}" 2>/dev/null; then break; fi
    sleep 0.1
  done
  stop_qemu
  if [[ ${found} -ne ${#EXPECTED[@]} ]]; then
    cat "${log}"
    echo "ESP32-C3 ${mode} firmware didn't run all containers." >&2
    exit 1
  fi
}

# With --native, but without --combine, the containers are compiled to native
# code on their own, so each of them has the code of the libraries it uses.
# That doesn't fit in the partitions of the standard firmware, so that mode
# runs with one big app partition.
BIG_PARTITIONS="${TEMP_DIR}/big-partitions.csv"
cat > "${BIG_PARTITIONS}" <<'EOF'
secure,   0x42, 0x00,     0x009000,  0x004000,
otadata,  data, ota,              ,  0x002000,
phy_init, data, phy,              ,  0x001000,
ota_0,    app,  ota_0,            ,  0x360000,
nvs,      data, nvs,              ,  0x010000,
programs, 0x40, 0x00,             ,  0x080000, encrypted
EOF

run_mode plain
run_mode combined --combine
run_mode native --native --partitions "${BIG_PARTITIONS}"
run_mode combined-native --combine --native

echo "All ESP32-C3 firmware modes passed."
