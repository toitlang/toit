#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the LGPL-2.1 license in LICENSE.

# Exercises the ROM flashing command without opening a USB device.
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
base="${1:-$root/build/rp2350-envelope-base/toit-rp2350.bin}"
system_snapshot="${2:-$root/.cache/rp2350/system.snapshot}"
partitions="${3:-$root/build/rp2350/partitions-experimental.uf2}"
toit="${TOIT:-$root/build/host/sdk/bin/toit}"
export TOIT_PACKAGE_CACHE_PATHS="${TOIT_PACKAGE_CACHE_PATHS:-$root/tools/.packages-bootstrap}"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
firmware=("$toit" run "$root/tools/firmware.toit" --)

"${firmware[@]}" --envelope="$temporary/base.envelope" create-rp2350 \
  --firmware.bin="$base" --system.snapshot="$system_snapshot" \
  --partition-table.uf2="$partitions"
"${firmware[@]}" --envelope="$temporary/base.envelope" extract \
  --format=image --output="$temporary/before.uf2"
"$toit" compile -s -o "$temporary/child.snapshot" "$root/tools/rp2350/tests/envelope_child.toit"
"${firmware[@]}" --envelope="$temporary/base.envelope" container install \
  --output="$temporary/current.envelope" child "$temporary/child.snapshot"
cat >"$temporary/config.json" <<'CONFIG'
{"enabled":true,"name":"flash-current-envelope"}
CONFIG
"${firmware[@]}" --envelope="$temporary/current.envelope" extract \
  --format=image --config="$temporary/config.json" --output="$temporary/expected.uf2"
if cmp -s "$temporary/before.uf2" "$temporary/expected.uf2"; then
  echo 'FAIL: adding a container and configuration did not change the recovery image' >&2
  exit 1
fi

cat >"$temporary/picotool" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >>"$RP2350_FLASH_TEST/calls"
case "$1" in
  load)
    [[ "$2" == --verify && "$3" == --ignore-partitions ]]
    printf '%s\n' "$4" >"$RP2350_FLASH_TEST/source-path"
    cp "$4" "$RP2350_FLASH_TEST/captured.uf2"
    shift 4
    ;;
  reboot) shift ;;
  *) exit 91 ;;
esac
if [[ -n "${RP2350_TEST_SERIAL:-}" ]]; then
  [[ $# == 2 && "$1" == --ser && "$2" == "$RP2350_TEST_SERIAL" ]]
else
  [[ $# == 0 ]]
fi
if [[ "${RP2350_TEST_FAIL:-}" == "$(tail -n 1 "$RP2350_FLASH_TEST/calls")" ]]; then
  exit 23
fi
MOCK
chmod +x "$temporary/picotool"
export PICOTOOL_PATH="$temporary/picotool"
export RP2350_FLASH_TEST="$temporary"
flash=("${firmware[@]}" --envelope="$temporary/current.envelope" flash)

for selector in omitted selected; do
  : >"$temporary/calls"
  extra=()
  export RP2350_TEST_SERIAL=''
  if [[ "$selector" == selected ]]; then
    export RP2350_TEST_SERIAL='DC67867C6256ED2B'
    extra=(--serial "$RP2350_TEST_SERIAL")
  fi
  "${flash[@]}" --bootloader --config="$temporary/config.json" "${extra[@]}"
  cmp "$temporary/expected.uf2" "$temporary/captured.uf2"
  printf 'load\nreboot\n' >"$temporary/expected-calls"
  cmp "$temporary/expected-calls" "$temporary/calls"
  [[ ! -e "$(cat "$temporary/source-path")" ]]
done

# A failed load must not reboot; a failed reboot must fail the command too.
for failure in load reboot; do
  : >"$temporary/calls"
  if RP2350_TEST_FAIL="$failure" "${flash[@]}" --bootloader \
      --serial "$RP2350_TEST_SERIAL" >"$temporary/failure.log" 2>&1; then
    echo "FAIL: picotool $failure failure was ignored" >&2
    exit 1
  fi
  if [[ "$failure" == load ]]; then
    printf 'load\n' >"$temporary/expected-calls"
  else
    printf 'load\nreboot\n' >"$temporary/expected-calls"
  fi
  cmp "$temporary/expected-calls" "$temporary/calls"
done

reject() {
  : >"$temporary/calls"
  if "${flash[@]}" "$@" >"$temporary/rejected.log" 2>&1; then
    echo "FAIL: accepted invalid flash options: $*" >&2
    exit 1
  fi
  [[ ! -s "$temporary/calls" ]]
}
reject
reject --serial SERIAL
reject --port /dev/null --serial SERIAL
reject --bootloader --port /dev/null
reject --bootloader --partitions "$partitions"
reject --bootloader --partition empty:unexpected=4096
# Exercise lookup from the installed SDK layout with no tool-path override.
# Copy the executable, rather than symlinking it: its actual program path is
# what resolves ../lib/toit/bin.
sdk="$temporary/sdk"
mkdir -p "$sdk/bin" "$sdk/lib/toit/bin"
cp "$toit" "$sdk/bin/toit"
cp "$temporary/picotool" "$sdk/lib/toit/bin/picotool"
: >"$temporary/calls"
(
  unset PICOTOOL_PATH RP2350_OTA_UPLOAD_PATH
  "$sdk/bin/toit" tool firmware --envelope="$temporary/current.envelope" \
    flash --bootloader --serial "$RP2350_TEST_SERIAL" --config="$temporary/config.json"
)
cmp "$temporary/expected.uf2" "$temporary/captured.uf2"
printf 'load\nreboot\n' >"$temporary/expected-calls"
cmp "$temporary/expected-calls" "$temporary/calls"

cat >"$sdk/lib/toit/bin/ota-upload" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ $# == 3 && "$1" == --port && "$2" == /dev/null ]]
cp "$3" "$RP2350_FLASH_TEST/captured.bin"
MOCK
chmod +x "$sdk/lib/toit/bin/ota-upload"
"${firmware[@]}" --envelope="$temporary/current.envelope" extract \
  --format=binary --config="$temporary/config.json" --output="$temporary/expected.bin"
(
  unset PICOTOOL_PATH RP2350_OTA_UPLOAD_PATH
  "$sdk/bin/toit" tool firmware --envelope="$temporary/current.envelope" \
    flash --port /dev/null --config="$temporary/config.json"
)
cmp "$temporary/expected.bin" "$temporary/captured.bin"
printf 'rp2350_flash_test: PASS envelope contents, selectors, failures, mode validation and SDK discovery\n'
