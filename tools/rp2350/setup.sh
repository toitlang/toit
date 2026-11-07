#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the LGPL-2.1 license that can be
# found in the LICENSE file.

# Downloads pinned upstream sources and installs picotool inside the workspace.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
work_dir="$repo_root/.cache/rp2350"
sdk_dir="${PICO_SDK_PATH:-$repo_root/third_party/pico-sdk}"
picotool_src="$work_dir/src/picotool"
install_dir="$work_dir/install"

for dependency in git cmake ninja pkg-config cc c++ python3; do
  command -v "$dependency" >/dev/null || {
    echo "Missing prerequisite: $dependency" >&2
    exit 1
  }
done
pkg-config --exists libusb-1.0 || {
  echo 'Install the libusb-1.0 development files before running this script.' >&2
  exit 1
}

checkout_release() {
  local name=$1 revision=$2 destination=$3
  if [[ ! -d "$destination" ]]; then
    git -c advice.detachedHead=false clone --depth 1 --branch 2.3.1 \
      "https://github.com/raspberrypi/$name.git" "$destination"
  fi
  if [[ "$(git -C "$destination" rev-parse HEAD)" != "$revision" ]]; then
    echo "Unexpected revision in $destination; expected $revision." >&2
    exit 1
  fi
  if [[ -n "$(git -C "$destination" status --porcelain --untracked-files=no)" ]]; then
    echo "Tracked files changed in $destination; refusing to build modified sources." >&2
    exit 1
  fi
}

mkdir -p "$work_dir/src"
if [[ ! -f "$sdk_dir/pico_sdk_init.cmake" ]]; then
  if [[ "$sdk_dir" != "$repo_root/third_party/pico-sdk" ]]; then
    echo "No Pico SDK at PICO_SDK_PATH=$sdk_dir" >&2
    exit 1
  fi
  git -C "$repo_root" submodule update --init third_party/pico-sdk
fi
# The parent repository pins the SDK commit, and the fork holds SDK patches.
# Preserve local SDK work; setup must not reset an existing checkout.
checkout_release picotool 2041936441b48a3cc53ae3da9e805229fe8f4e18 "$picotool_src"

# mbedTLS supplies hashing/signing; TinyUSB prepares the SDK for USB firmware.
git -C "$sdk_dir" submodule update --init --depth 1 lib/mbedtls lib/tinyusb
git -C "$sdk_dir/lib/mbedtls" submodule update --init --depth 1 framework
git -C "$repo_root" submodule update --init third_party/FreeRTOS-Kernel
git -C "$repo_root/third_party/FreeRTOS-Kernel" submodule update --init \
  portable/ThirdParty/Community-Supported-Ports

cmake -S "$picotool_src" -B "$work_dir/build/picotool" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$install_dir" \
  -DPICO_SDK_PATH="$sdk_dir" \
  -DPICOTOOL_NO_LIBUSB=OFF
cmake --build "$work_dir/build/picotool" --parallel "${CMAKE_BUILD_PARALLEL_LEVEL:-4}"
cmake --install "$work_dir/build/picotool"

"$install_dir/bin/picotool" version
"$install_dir/bin/picotool" help load >/dev/null
printf '\nInstalled picotool: %s/bin/picotool\nPico SDK: %s\n' "$install_dir" "$sdk_dir"
printf '\nThe SDK selects arm-none-eabi-gcc from PATH by default.\n'
printf 'Use -DPICO_TOOLCHAIN_PATH=/path/to/toolchain to select another installation.\n'
if command -v arm-none-eabi-gcc >/dev/null; then
  arm-none-eabi-gcc --version | head -n 1
else
  echo 'Install Arm GNU GCC (including newlib and libstdc++) before building firmware.'
fi
