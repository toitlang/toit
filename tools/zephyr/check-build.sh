#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the LGPL-2.1 license in LICENSE.
# Build the supported nRF profiles and run the native GATT tests, without hardware.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
if [[ $# -gt 1 || ${1:-} == --help ]]; then
  echo "Usage: $0 [build-directory]"
  echo "Run tools/zephyr/setup.sh first. See docs/nrf5340.md for dependencies."
  exit "$(( $# > 1 ))"
fi
build=${1:-"$root/build/zephyr-check"}
mkdir -p "$build"
build=$(cd -- "$build" && pwd)
cd "$root"
export ZEPHYR_BASE=${ZEPHYR_BASE:-"$root/.cache/zephyr-workspace/zephyr"}
export GNUARMEMB_TOOLCHAIN_PATH=${GNUARMEMB_TOOLCHAIN_PATH:-/usr}
export ZEPHYR_TOOLCHAIN_VARIANT=gnuarmemb
export IDF_PATH="$root/third_party/esp-idf"
python=${ZEPHYR_PYTHON:-"$root/.cache/zephyr-venv/bin/python"}
jobs=${CMAKE_BUILD_PARALLEL_LEVEL:-4}
[[ -x "$python" ]] || { echo "Missing Zephyr Python: $python" >&2; exit 1; }
[[ -f "$ZEPHYR_BASE/zephyr-env.sh" ]] || { echo "Missing Zephyr checkout: $ZEPHYR_BASE" >&2; exit 1; }

run() {
  local label=$1
  shift
  echo "$label"
  if ! "$@" > "$build/$label.log" 2>&1; then
    tail -80 "$build/$label.log" >&2
    echo "Failed: $label (full log: $build/$label.log)" >&2
    exit 1
  fi
}

run host-configure cmake -S "$root" -B "$build/host" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_TOOLCHAIN_FILE="$root/toolchains/host.cmake" \
  -DTOIT_PKG_AUTO_SYNC=OFF
run host-build cmake --build "$build/host" --target build_tools -j "$jobs"
host="$build/host/sdk/bin/toit"
run tools-packages "$host" pkg install --no-auto-sync --project-root="$root/tools"
run test-packages "$host" pkg install --no-auto-sync --project-root="$root/tests"
run firmware-tests "$host" run "$root/tests/zephyr-firmware-test.toit"

for profile in default ble secure; do
  options=("-DEXTRA_CONF_FILE=" "-DDTC_OVERLAY_FILE="
    "-DTOIT_ZEPHYR_PROGRAM=$root/tests/hw/nrf5340/vm-smoke.toit")
  if [[ $profile != default ]]; then
    options+=("-DDTC_OVERLAY_FILE=$root/toolchains/zephyr/bluetooth.overlay")
    if [[ $profile == secure ]]; then
      options+=("-DEXTRA_CONF_FILE=bluetooth.conf;settings.conf;bluetooth-security.conf"
        "-DTOIT_ZEPHYR_PROGRAM=$root/tests/hw/nrf5340/ble-notify-security-nrf5340.toit")
    else
      options+=("-DEXTRA_CONF_FILE=bluetooth.conf"
        "-DTOIT_ZEPHYR_PROGRAM=$root/tests/hw/nrf5340/ble-nrf5340.toit")
    fi
  fi
  run "$profile-configure" cmake -S "$root/toolchains/zephyr" -B "$build/$profile" -G Ninja \
    -DBOARD=e83_2g4m03s_tb/nrf5340/cpuapp -DPython3_EXECUTABLE="$python" \
    -DTOIT_HOST="$host" -DTOIT_ZEPHYR_BUILD_VM=ON -DTOIT_ZEPHYR_STARTUP_TEST= \
    -DTOIT_ZEPHYR_PROGRAM_ASSETS= -DTOIT_ZEPHYR_BUNDLED_IMAGES= "${options[@]}"
  run "$profile-build" cmake --build "$build/$profile" --target toit_envelope -j "$jobs"
  run "$profile-envelope" "$host" tool firmware --envelope="$build/$profile/toit.envelope" show
  if [[ $profile == default ]]; then
    run "$profile-extract" "$host" tool firmware --envelope="$build/$profile/toit.envelope" \
      extract -o "$build/$profile/extracted.bin"
  else
    run "$profile-extract" "$host" tool firmware --envelope="$build/$profile/toit.envelope" \
      extract --format=tar -o "$build/$profile/firmware.tar"
  fi
done

run envelope-integration python3 "$root/tests/hw/nrf5340/test-envelope.py" "$build"
peripheral_output=$(mktemp -d "$build/peripherals.XXXXXX")
run peripheral-packaging python3 "$root/tests/hw/nrf5340/check-peripherals.py" \
  --toit "$host" --envelope "$build/default/toit.envelope" \
  --log-dir "$peripheral_output/prepared" --prepare-only

run controller-configure cmake -S "$ZEPHYR_BASE/samples/bluetooth/hci_ipc" -B "$build/controller" -G Ninja \
  -DBOARD=e83_2g4m03s_tb/nrf5340/cpunet -DBOARD_ROOT="$root/toolchains/zephyr" \
  -DPython3_EXECUTABLE="$python" -DEXTRA_CONF_FILE="$root/toolchains/zephyr/hci-ipc.conf"
run controller-build cmake --build "$build/controller" -j "$jobs"

run native-configure env ZEPHYR_TOOLCHAIN_VARIANT=host \
  cmake -S "$root/tests/hw/nrf5340/ble-native-tests" -B "$build/native" -G Ninja \
  -DBOARD=native_sim/native/64 -DPython3_EXECUTABLE="$python"
run native-build cmake --build "$build/native" -j "$jobs"
run native-tests env ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 \
  UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 timeout 45s "$build/native/zephyr/zephyr.exe"
echo "Zephyr build checks passed. Logs and images: $build"
