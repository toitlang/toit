#!/usr/bin/env bash

# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

set -euo pipefail

if (( $# < 2 )); then
  echo "Usage: $0 JAGUAR_SNAPSHOT ENVELOPE..." >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOIT="${TOIT:-${ROOT_DIR}/build/host/sdk/bin/toit}"
JAGUAR_SNAPSHOT="$1"
shift

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TEMP_DIR}"' EXIT

# Include representative Jaguar assets and WiFi configuration. The snapshot
# must be compiled with the SDK under test, just like the system snapshot in
# each envelope. The chip value only affects asset size; no firmware is run.
cat > "${TEMP_DIR}/jaguar.json" <<'EOF'
{"id":"00000000-0000-0000-0000-000000000001","name":"partition-size-check","chip":"esp32s3"}
EOF
cat > "${TEMP_DIR}/config.json" <<'EOF'
{"wifi":{"wifi.ssid":"partition-size-check","wifi.password":"partition-size-check"}}
EOF
"${TOIT}" tool assets -e "${TEMP_DIR}/jaguar.assets" create
"${TOIT}" tool assets -e "${TEMP_DIR}/jaguar.assets" add \
  --format=tison config "${TEMP_DIR}/jaguar.json"

check_image() {
  # Image extraction checks the envelope's own partition table after adding
  # the containers, assets, configuration, and ESP32 flash-page padding.
  # Do not use Jaguar's CLI here: its partition overrides can mask SDK bugs.
  "${TOIT}" tool firmware -e "$1" extract --format=image \
    --config "${TEMP_DIR}/config.json" -o "${TEMP_DIR}/firmware.bin"
}

failed=0
for envelope in "$@"; do
  echo "Checking ${envelope} (system only)"
  if check_image "${envelope}"; then
    echo "PASS: ${envelope} (system only)"
  else
    echo "FAIL: ${envelope} (system only)" >&2
    failed=1
  fi

  echo "Checking ${envelope} (with Jaguar)"
  if "${TOIT}" tool firmware -e "${envelope}" container install \
      -o "${TEMP_DIR}/jaguar.envelope" \
      --assets "${TEMP_DIR}/jaguar.assets" --trigger=boot --critical \
      jaguar "${JAGUAR_SNAPSHOT}" &&
      check_image "${TEMP_DIR}/jaguar.envelope"; then
    echo "PASS: ${envelope} (with Jaguar)"
  else
    echo "FAIL: ${envelope} (with Jaguar)" >&2
    failed=1
  fi
done

exit "${failed}"
