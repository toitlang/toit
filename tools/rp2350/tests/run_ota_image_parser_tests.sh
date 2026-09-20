#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the LGPL-2.1 license in LICENSE.

set -euo pipefail

root="$(cd "$(dirname "$0")/../../.." && pwd)"
export TOIT_PACKAGE_CACHE_PATHS="${TOIT_PACKAGE_CACHE_PATHS:-$root/tools/.packages-bootstrap}"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT

if (( $# > 0 )); then
  images=("$@")
else
  images=()
  candidates=(
    "$root/build/rp2350/toit-rp2350-ota-probe.bin"
    "$root/build/rp2350-vm/toit-rp2350.bin"
    "$root/build/rp2350-update-v1/toit-rp2350.bin"
  )
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then images+=("$candidate"); fi
  done
  if (( ${#images[@]} == 0 )); then
    echo "FAIL: no RP2350 OTA images found; pass one or more .bin paths" >&2
    exit 1
  fi
fi

compiler="${CXX:-c++}"
"$compiler" -std=c++17 -Wall -Wextra -Werror \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -DTOIT_RP2350_OTA_TEST \
  -I"$root/src" \
  -I"$root/third_party/pico-sdk/src/common/boot_picobin_headers/include" \
  "$root/src/ota_image_rp2350.cc" \
  "$root/tools/rp2350/tests/ota_image_parser_test.cc" \
  -o "$temporary/ota_image_parser_test"

picotool="${PICOTOOL:-}"
if [[ -n "$picotool" && ! -x "$picotool" && -x "$root/$picotool" ]]; then
  picotool="$root/$picotool"
fi
if [[ -z "$picotool" ]]; then
  candidates=(
    "$root/build/rp2350-flasher/linux-x86_64/picotool"
    "$root/.cache/rp2350/install/bin/picotool"
    "$root/.cache/rp2350/build/picotool/picotool"
    "$root/.cache/rp2350/build/picotool-distribution/picotool"
  )
  for candidate in "${candidates[@]}"; do
    if [[ -x "$candidate" ]]; then
      picotool="$candidate"
      break
    fi
  done
  if [[ -z "$picotool" ]] && command -v picotool >/dev/null 2>&1; then
    picotool="$(command -v picotool)"
  fi
fi
if [[ -n "$picotool" && ! -x "$picotool" ]]; then
  echo "FAIL: PICOTOOL is not executable: $picotool" >&2
  exit 1
fi
if [[ -z "$picotool" ]]; then
  if [[ "${REQUIRE_PICOTOOL:-0}" == 1 ]]; then
    echo "FAIL: picotool was not found" >&2
    exit 1
  fi
  echo "SKIP: picotool was not found; Toit digest checks still run" >&2
fi

for image in "${images[@]}"; do
  ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 \
  UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
    "$temporary/ota_image_parser_test" "$image"
  ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 \
    "${TOIT:-$root/build/host/sdk/bin/toit}" run "$root/tools/rp2350/tests/ota-image-hash-test.toit" -- \
      "$temporary/ota_image_parser_test" "$image"
  if [[ -n "$picotool" ]]; then
    information="$($picotool info -a "$image")"
    if ! grep -q 'hash: *verified' <<<"$information"; then
      echo "FAIL: picotool did not verify $image" >&2
      exit 1
    fi
    echo "ota_image_picotool_test: PASS $image"
  fi
done
