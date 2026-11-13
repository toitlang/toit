#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

# Runs the firmware of a host envelope in the ways the firmware tool can
# extract it. Envelopes for other architectures ('make TARGET=<target> sdk')
# run with qemu-user.
#
# Usage: tests/cross/run-envelope-tests.sh <target>
# where <target> is host, aarch64, riscv64, armv7, raspbian,
# arm-linux-gnueabi, or host32.
#
# The envelope's 'run-image' runs with the loader and libraries of the
# sysroot that the target was built with (build/<target>/sysroot). The
# firmware of the host and of the 32-bit x86 target (host32) runs directly,
# with the libraries of the host.
#
# If the SDK of the target has a native folder, the firmware is also
# extracted as native code. The generated code is compiled with clang++, or
# with TOIT_NATIVE_CXX, which must be able to compile for the target.

set -euo pipefail

TARGET="${1:?Usage: $0 <target>}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOIT="${TOIT:-${ROOT_DIR}/build/host/sdk/bin/toit}"
ENVELOPE="${ENVELOPE:-${ROOT_DIR}/build/${TARGET}/firmware.envelope}"
SYSROOT="${SYSROOT:-${ROOT_DIR}/build/${TARGET}/sysroot}"

case "${TARGET}" in
  host) QEMU=""; CLANG_TARGET="$(uname -m)-linux-gnu" ;;
  aarch64) QEMU=qemu-aarch64; CLANG_TARGET=aarch64-linux-gnu ;;
  riscv64) QEMU=qemu-riscv64; CLANG_TARGET=riscv64-linux-gnu ;;
  armv7|raspbian) QEMU=qemu-arm; CLANG_TARGET=arm-linux-gnueabihf ;;
  arm-linux-gnueabi) QEMU=qemu-arm; CLANG_TARGET=arm-linux-gnueabi ;;
  host32) QEMU=""; CLANG_TARGET=i686-linux-gnu ;;
  *) echo "Unknown target: ${TARGET}" >&2; exit 2 ;;
esac
QEMU="${QEMU_USER:-${QEMU}}"

RUNNER=()
if [[ -n "${QEMU}" ]]; then
  if ! command -v "${QEMU}" >/dev/null 2>&1; then
    echo "QEMU executable not found: ${QEMU}" >&2
    exit 2
  fi
  if [[ ! -d "${SYSROOT}" ]]; then
    echo "Sysroot not found: ${SYSROOT}" >&2
    exit 2
  fi
  RUNNER=("${QEMU}" -L "${SYSROOT}")
fi
if [[ ! -f "${ENVELOPE}" ]]; then
  echo "Envelope not found: ${ENVELOPE}" >&2
  exit 2
fi

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TEMP_DIR}"' EXIT

# Two containers that are installed from source, so they can be combined, and
# one that runs a snapshot, which always runs its bytecodes.
mkdir -p "${TEMP_DIR}/app"
touch "${TEMP_DIR}/app/package.yaml"
cat > "${TEMP_DIR}/app/first.toit" <<'EOF'
fib n/int -> int: return n < 2 ? n : (fib n - 1) + (fib n - 2)
main: print "TOIT-CROSS-FIRST: $(fib 20)"
EOF
cat > "${TEMP_DIR}/app/second.toit" <<'EOF'
main:
  // Doubles and integers that don't fit in a small integer go through the
  // runtime of native code.
  sum := 0.0
  10.repeat: sum += it * 0.5
  big := 1
  62.repeat: big *= 2
  print "TOIT-CROSS-SECOND: $(List 10: it * it) $sum $(1.5 * 2.25) $(1 << 62) $(big >> 52)"
EOF
cat > "${TEMP_DIR}/app/snapshot.toit" <<'EOF'
main: print "TOIT-CROSS-SNAPSHOT"
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
  "TOIT-CROSS-FIRST: 6765"
  "TOIT-CROSS-SECOND: [0, 1, 4, 9, 16, 25, 36, 49, 64, 81] 22.5 3.375 4611686018427387904 1024"
  "TOIT-CROSS-SNAPSHOT"
)

run_mode() {
  local mode="$1"
  shift
  local dir="${TEMP_DIR}/${mode}"
  echo "=== ${TARGET} ${mode}"
  mkdir -p "${dir}/inactive"
  "${TOIT}" tool firmware -e "${ENVELOPE_WITH_CONTAINERS}" extract "$@" \
      --format=tar -o "${dir}/firmware.tar"
  tar x -f "${dir}/firmware.tar" -C "${dir}"
  local output
  output="$(timeout 120 "${RUNNER[@]}" "${dir}/ota0/run-image" \
      "${dir}/ota0" "${dir}/inactive" 2>&1)" || true
  for line in "${EXPECTED[@]}"; do
    if [[ "${output}" != *"${line}"* ]]; then
      echo "${output}"
      echo "${TARGET} ${mode} firmware didn't print: ${line}" >&2
      exit 1
    fi
  done
}

run_mode plain
run_mode combined --combine

NATIVE_DIR="${ROOT_DIR}/build/${TARGET}/sdk/lib/toit/native"
if [[ -n "${CLANG_TARGET}" && -f "${NATIVE_DIR}/native.flags" ]]; then
  native_support=(--directory "${NATIVE_DIR}" --target "${CLANG_TARGET}")
  if [[ -n "${QEMU}" ]]; then
    native_support+=(--sysroot "${TARGET}")
    export TOIT_SYSROOT="${SYSROOT}"
  fi
  "${TOIT}" tool firmware -e "${ENVELOPE_WITH_CONTAINERS}" native-support add "${native_support[@]}"
  run_mode native --native
  run_mode combined-native --combine --native
fi

echo "All ${TARGET} firmware modes passed."
