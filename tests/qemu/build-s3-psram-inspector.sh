#!/usr/bin/env bash

# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="${1:-${ROOT_DIR}/build/esp32s3-qemu-psram}"
SDKCONFIG="${BUILD_DIR}/sdkconfig.qemu-psram"
TOIT="${TOIT:-${ROOT_DIR}/build/host/sdk/bin/toit}"

if [[ ! -x "${TOIT}" ]]; then
  echo "Toit executable not found: ${TOIT}" >&2
  exit 2
fi

mkdir -p "${BUILD_DIR}"
cp "${ROOT_DIR}/toolchains/esp32s3/sdkconfig" "${SDKCONFIG}"
sed -i \
  -e 's/^CONFIG_SPIRAM_MODE_QUAD=y$/# CONFIG_SPIRAM_MODE_QUAD is not set/' \
  -e 's/^# CONFIG_SPIRAM_MODE_OCT is not set$/CONFIG_SPIRAM_MODE_OCT=y/' \
  -e 's/^CONFIG_SPIRAM_IGNORE_NOTFOUND=y$/# CONFIG_SPIRAM_IGNORE_NOTFOUND is not set/' \
  "${SDKCONFIG}"

export IDF_PATH="${ROOT_DIR}/third_party/esp-idf"
export TOIT_VM_STATE_CHECKPOINTS=1
source "${IDF_PATH}/export.sh"
IDF_TARGET=esp32s3 IDF_CCACHE_ENABLE=1 python \
  "${IDF_PATH}/tools/idf.py" \
  -C "${ROOT_DIR}/toolchains/esp32s3" \
  -B "${BUILD_DIR}" \
  -D "SDKCONFIG=${SDKCONFIG}" \
  build

CONFIG_HEADER="${BUILD_DIR}/config/sdkconfig.h"
if ! grep -q '^#define CONFIG_SPIRAM 1$' "${CONFIG_HEADER}" ||
    ! grep -q '^#define CONFIG_SPIRAM_MODE_OCT 1$' "${CONFIG_HEADER}" ||
    ! grep -q '^#define CONFIG_TOIT_SPIRAM_HEAP 1$' "${CONFIG_HEADER}" ||
    grep -q '^#define CONFIG_SPIRAM_IGNORE_NOTFOUND 1$' "${CONFIG_HEADER}"; then
  echo "ESP32-S3 QEMU octal PSRAM heap configuration was not selected." >&2
  exit 1
fi

"${TOIT}" compile --snapshot \
  -o "${BUILD_DIR}/device-inspector.snapshot" \
  "${ROOT_DIR}/tests/qemu/device-inspector-fixture.toit"
"${TOIT}" run --project-root "${ROOT_DIR}/tools" \
  "${ROOT_DIR}/tools/device-inspector/extract-program-layout.toit" -- \
  "${BUILD_DIR}/device-inspector.snapshot" \
  "${BUILD_DIR}/program-layout.json"
"${TOIT}" run --project-root "${ROOT_DIR}/tools" \
  "${ROOT_DIR}/tools/device-inspector/extract-program-layout.toit" -- \
  "${BUILD_DIR}/system.snapshot" \
  "${BUILD_DIR}/system-program-layout.json"
"${TOIT}" tool firmware --envelope="${BUILD_DIR}/firmware.envelope" \
  container install -o "${BUILD_DIR}/device-inspector.envelope" \
  inspector "${BUILD_DIR}/device-inspector.snapshot"
"${TOIT}" tool firmware --envelope="${BUILD_DIR}/device-inspector.envelope" \
  extract --format=image -o "${BUILD_DIR}/device-inspector.bin"
"${TOIT}" tool firmware --envelope="${BUILD_DIR}/device-inspector.envelope" \
  extract --format=elf -o "${BUILD_DIR}/device-inspector.elf"

echo "Built ESP32-S3 octal-PSRAM inspector fixture in ${BUILD_DIR}"
