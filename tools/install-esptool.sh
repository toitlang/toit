#!/usr/bin/env bash

# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 SDK-DIRECTORY" >&2
  exit 1
fi

SDK_DIR="$1"
VERSION="${ESPTOOL_VERSION:-v5.1.0%2Btoitlang.universal}"
SYSTEM="$(uname -s)"
MACHINE="$(uname -m)"
EXTENSION=""
ARCHIVE_EXTENSION=".tar.gz"

case "${SYSTEM}" in
  Linux)
    case "${MACHINE}" in
      x86_64) ARCH="linux-amd64" ;;
      armv7l) ARCH="linux-armv7" ;;
      aarch64|arm64) ARCH="linux-aarch64" ;;
      riscv64) ARCH="linux-riscv64" ;;
      *) echo "unsupported Linux architecture: ${MACHINE}" >&2; exit 1 ;;
    esac
    ;;
  Darwin)
    # The macOS aarch64 artifact is a universal binary.
    ARCH="macos-aarch64"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    ARCH="windows-amd64"
    EXTENSION=".exe"
    ARCHIVE_EXTENSION=".zip"
    ;;
  *)
    echo "unsupported operating system: ${SYSTEM}" >&2
    exit 1
    ;;
esac

TARGET_DIR="${SDK_DIR}/lib/toit/bin"
TARGET="${TARGET_DIR}/esptool${EXTENSION}"
EXPECTED_VERSION="${VERSION#v}"
EXPECTED_VERSION="${EXPECTED_VERSION%%\%*}"
if [[ -x "${TARGET}" ]]; then
  INSTALLED_VERSION="$("${TARGET}" version 2>/dev/null || true)"
  if [[ "${INSTALLED_VERSION}" == *"esptool v${EXPECTED_VERSION}"* ]]; then
    echo "esptool ${EXPECTED_VERSION} is already installed in ${SDK_DIR}"
    exit 0
  fi
fi

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/toit-esptool.XXXXXX")"
trap 'rm -rf "${TEMP_DIR}"' EXIT

ARCHIVE="esptool-${ARCH}${ARCHIVE_EXTENSION}"
URL="https://github.com/toitlang/esptool/releases/download/${VERSION}/${ARCHIVE}"
curl --location --fail --output "${TEMP_DIR}/${ARCHIVE}" "${URL}"

if [[ "${ARCHIVE_EXTENSION}" == ".zip" ]]; then
  unzip -q "${TEMP_DIR}/${ARCHIVE}" -d "${TEMP_DIR}"
else
  tar -xzf "${TEMP_DIR}/${ARCHIVE}" -C "${TEMP_DIR}"
fi

mkdir -p "${TARGET_DIR}"
cp "${TEMP_DIR}/esptool-${ARCH}/esptool${EXTENSION}" "${TARGET}"
chmod +x "${TARGET}"
