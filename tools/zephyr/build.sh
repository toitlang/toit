#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the LGPL-2.1 license in LICENSE.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
board=e83_2g4m03s_tb/nrf5340/cpuapp
build="$root/build/zephyr-custom"
host="${TOIT_HOST:-$root/build/host/sdk/bin/toit}"
config=
overlay=
program="$root/tests/hw/nrf5340/vm-smoke.toit"
menuconfig=false
usage() {
  cat <<'USAGE'
Usage: tools/zephyr/build.sh [options]
  --config FILE      Kconfig fragment, like an ESP32 sdkconfig (optional).
  --overlay FILE     Devicetree changes for console, controllers and pins.
  --board BOARD      Zephyr board target (default: e83_2g4m03s_tb/nrf5340/cpuapp).
  --build-dir DIR    Separate output directory for this envelope variant.
  --host FILE        Matching host Toit executable.
  --program FILE    Bundled Toit program; use an empty value for system only.
  --menuconfig      Edit the configured options before building the envelope.
  --help            Show this help.
Output: BUILD_DIR/toit.envelope. This command does not access hardware.
USAGE
}
absolute_file() {
  [[ -f "$1" ]] || { echo "Missing input: $1" >&2; exit 1; }
  local parent
  parent=$(cd -- "$(dirname -- "$1")" && pwd)
  echo "$parent/$(basename -- "$1")"
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help) usage; exit 0 ;;
    --menuconfig) menuconfig=true; shift; continue ;;
    --config|--overlay|--board|--build-dir|--host|--program)
      [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 1; } ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
  case "$1" in
    --config) config=$(absolute_file "$2") ;;
    --overlay) overlay=$(absolute_file "$2") ;;
    --board) board=$2 ;;
    --build-dir) build=$2 ;;
    --host) host=$(absolute_file "$2") ;;
    --program) program=$2; [[ -z "$program" ]] || program=$(absolute_file "$program") ;;
  esac
  shift 2
done
[[ -x "$host" ]] || { echo "Build the host SDK or pass --host." >&2; exit 1; }
export ZEPHYR_BASE=${ZEPHYR_BASE:-"$root/.cache/zephyr-workspace/zephyr"}
export ZEPHYR_TOOLCHAIN_VARIANT=${ZEPHYR_TOOLCHAIN_VARIANT:-gnuarmemb}
export GNUARMEMB_TOOLCHAIN_PATH=${GNUARMEMB_TOOLCHAIN_PATH:-/usr}
python=${ZEPHYR_PYTHON:-"$root/.cache/zephyr-venv/bin/python"}
[[ -x "$python" && -f "$ZEPHYR_BASE/zephyr-env.sh" ]] || {
  echo "Run tools/zephyr/setup.sh or set ZEPHYR_BASE and ZEPHYR_PYTHON." >&2
  exit 1
}
cmake -S "$root/toolchains/zephyr" -B "$build" -G Ninja   -DBOARD="$board" -DPython3_EXECUTABLE="$python" -DTOIT_HOST="$host"   -DEXTRA_CONF_FILE="$config" -DDTC_OVERLAY_FILE="$overlay"   -DTOIT_ZEPHYR_PROGRAM="$program"
if "$menuconfig"; then
  cmake --build "$build" --target menuconfig
fi
cmake --build "$build" --target toit_envelope -j "${CMAKE_BUILD_PARALLEL_LEVEL:-4}"
echo "Envelope: $build/toit.envelope"
