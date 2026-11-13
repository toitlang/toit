#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

# Runs the firmware of a host envelope that was built for another
# architecture ('make TARGET=<target> sdk') with qemu-user, in the ways the
# firmware tool can extract it.
#
# Usage: tests/cross/run-envelope-tests.sh <target>
# where <target> is aarch64, riscv64, armv7, raspbian, arm-linux-gnueabi, or
# host32.
#
# The envelope's 'run-image' runs with the loader and libraries of the
# sysroot that the target was built with (build/<target>/sysroot). The
# 32-bit x86 firmware (host32) runs directly, with the libraries of the host.

set -euo pipefail

TARGET="${1:?Usage: $0 <target>}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOIT="${TOIT:-${ROOT_DIR}/build/host/sdk/bin/toit}"
ENVELOPE="${ENVELOPE:-${ROOT_DIR}/build/${TARGET}/firmware.envelope}"
SYSROOT="${SYSROOT:-${ROOT_DIR}/build/${TARGET}/sysroot}"

case "${TARGET}" in
  aarch64) QEMU=qemu-aarch64 ;;
  riscv64) QEMU=qemu-riscv64 ;;
  armv7|raspbian|arm-linux-gnueabi) QEMU=qemu-arm ;;
  host32) QEMU="" ;;
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
main: print "TOIT-CROSS-SECOND: $(List 10: it * it)"
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
  "TOIT-CROSS-SECOND: [0, 1, 4, 9, 16, 25, 36, 49, 64, 81]"
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

echo "All ${TARGET} firmware modes passed."
