#!/usr/bin/env bash

# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="${1:-${ROOT_DIR}/build/esp32s3-usj}"
SDKCONFIG="${BUILD_DIR}/sdkconfig.usj"

mkdir -p "${BUILD_DIR}"
cp "${ROOT_DIR}/toolchains/esp32s3/sdkconfig" "${SDKCONFIG}"
sed -i \
  -e 's/^CONFIG_ESP_CONSOLE_UART_DEFAULT=y$/# CONFIG_ESP_CONSOLE_UART_DEFAULT is not set/' \
  -e 's/^# CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG is not set$/CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG=y/' \
  -e 's/^# CONFIG_ESP_CONSOLE_SECONDARY_NONE is not set$/CONFIG_ESP_CONSOLE_SECONDARY_NONE=y/' \
  -e 's/^CONFIG_ESP_CONSOLE_SECONDARY_USB_SERIAL_JTAG=y$/# CONFIG_ESP_CONSOLE_SECONDARY_USB_SERIAL_JTAG is not set/' \
  -e 's/^CONFIG_ESP_CONSOLE_UART=y$/# CONFIG_ESP_CONSOLE_UART is not set/' \
  -e 's/^CONFIG_CONSOLE_UART_DEFAULT=y$/# CONFIG_CONSOLE_UART_DEFAULT is not set/' \
  -e 's/^CONFIG_CONSOLE_UART=y$/# CONFIG_CONSOLE_UART is not set/' \
  "${SDKCONFIG}"

export IDF_PATH="${ROOT_DIR}/third_party/esp-idf"
source "${IDF_PATH}/export.sh"
IDF_TARGET=esp32s3 IDF_CCACHE_ENABLE=1 python \
  "${IDF_PATH}/tools/idf.py" \
  -C "${ROOT_DIR}/toolchains/esp32s3" \
  -B "${BUILD_DIR}" \
  -D "SDKCONFIG=${SDKCONFIG}" \
  build

CONFIG_HEADER="${BUILD_DIR}/config/sdkconfig.h"
if ! grep -q '^#define CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG 1$' "${CONFIG_HEADER}" ||
    grep -q '^#define CONFIG_ESP_CONSOLE_UART 1$' "${CONFIG_HEADER}"; then
  echo "ESP32-S3 USB Serial/JTAG console configuration was not selected." >&2
  exit 1
fi
