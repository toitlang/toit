#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the LGPL-2.1 license that can be
# found in the LICENSE file.

# Builds the Linux distribution flasher. SDK/compiler dependencies are build
# dependencies only; the resulting executable needs no separately installed
# libusb, libudev, libstdc++, Python, or SDK data files.
set -euo pipefail

if [[ $(uname -s) != Linux ]]; then
  echo 'This packaging recipe currently supports Linux hosts only.' >&2
  exit 1
fi

picotool_version=2.3.1
picotool_revision=2041936441b48a3cc53ae3da9e805229fe8f4e18
libusb_version=1.0.30
libusb_sha256=fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf
architecture=$(uname -m)
case "$architecture" in
  x86_64) dynamic_loader=ld-linux-x86-64.so.2 ;;
  aarch64) dynamic_loader=ld-linux-aarch64.so.1 ;;
  *)
    echo "No reviewed runtime-library policy for Linux architecture: $architecture" >&2
    exit 1
    ;;
esac

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source_bundle=false
if [[ -f "$script_dir/picotool-$picotool_version.tar.gz" &&
      -f "$script_dir/pico-sdk-$picotool_version.tar.gz" &&
      -f "$script_dir/pico-sdk-mbedtls.tar.gz" &&
      -f "$script_dir/libusb-$libusb_version.tar.bz2" ]]; then
  # A copy of this script is included with the corresponding sources. This
  # mode lets a recipient rebuild and relink the statically linked libusb.
  source_bundle=true
  work_dir="${RP2350_BUILD_ROOT:-$script_dir/rebuild-work}"
  output="${RP2350_FLASHER_OUTPUT:-$script_dir/rebuilt/linux-$architecture}"
  archive="$script_dir/libusb-$libusb_version.tar.bz2"
  picotool_src="$work_dir/src/picotool-$picotool_version"
  sdk_dir="$work_dir/src/pico-sdk-$picotool_version"
  libusb_src="$work_dir/src/libusb-$libusb_version"
else
  repo_root=$(cd -- "$script_dir/../.." && pwd)
  work_dir="$repo_root/.cache/rp2350"
  output="$repo_root/build/rp2350-flasher/linux-$architecture"
  archive="$work_dir/downloads/libusb-$libusb_version.tar.bz2"
  picotool_src="$work_dir/src/picotool"
  sdk_dir="${PICO_SDK_PATH:-$repo_root/third_party/pico-sdk}"
  libusb_src="$work_dir/src/libusb-$libusb_version"
fi
libusb_install="$work_dir/install/libusb-static"

for dependency in sha256sum tar make cmake ninja cc c++ python3 readelf; do
  command -v "$dependency" >/dev/null || {
    echo "Missing build prerequisite: $dependency" >&2
    exit 1
  }
done
if [[ $source_bundle == false ]]; then
  command -v git >/dev/null || {
    echo 'Missing build prerequisite: git' >&2
    exit 1
  }
  if [[ ! -f "$archive" ]]; then
    command -v curl >/dev/null || {
      echo 'Missing build prerequisite: curl' >&2
      exit 1
    }
  fi
fi

mkdir -p "$work_dir/downloads" "$work_dir/src" \
  "$work_dir/build/libusb-static" "$output/licenses" "$output/sources"
if [[ $source_bundle == true ]]; then
  (cd "$script_dir" && sha256sum --check SHA256SUMS)
  if [[ ! -f "$picotool_src/CMakeLists.txt" ]]; then
    tar -xzf "$script_dir/picotool-$picotool_version.tar.gz" -C "$work_dir/src"
  fi
  if [[ ! -f "$sdk_dir/pico_sdk_init.cmake" ]]; then
    tar -xzf "$script_dir/pico-sdk-$picotool_version.tar.gz" -C "$work_dir/src"
  fi
  if [[ ! -f "$sdk_dir/lib/mbedtls/library/aes.c" ]]; then
    tar -xzf "$script_dir/pico-sdk-mbedtls.tar.gz" -C "$work_dir/src"
  fi
else
  if [[ ! -f "$archive" ]]; then
    curl --fail --location --retry 3 --output "$archive.part" \
      "https://github.com/libusb/libusb/releases/download/v$libusb_version/libusb-$libusb_version.tar.bz2"
    mv "$archive.part" "$archive"
  fi
  if [[ ! -f "$picotool_src/CMakeLists.txt" || ! -f "$sdk_dir/pico_sdk_init.cmake" ]]; then
    echo 'Run make rp2350-setup first.' >&2
    exit 1
  fi
  if [[ $(git -C "$picotool_src" rev-parse HEAD) != "$picotool_revision" ]]; then
    echo 'Unexpected picotool revision; rerun setup with the pinned sources.' >&2
    exit 1
  fi
fi

echo "$libusb_sha256  $archive" | sha256sum --check -
if [[ ! -f "$libusb_src/configure" ]]; then
  tar -xjf "$archive" -C "$work_dir/src"
fi

# The Linux netlink backend avoids a runtime dependency on libudev. Device
# permissions are still enforced; the supplied udev rules configure access.
(
  cd "$work_dir/build/libusb-static"
  "$libusb_src/configure" --prefix="$libusb_install" \
    --disable-shared --enable-static --disable-udev
  make -j "${CMAKE_BUILD_PARALLEL_LEVEL:-4}"
  make install
)

cmake -S "$picotool_src" -B "$work_dir/build/picotool-distribution" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DPICO_SDK_PATH="$sdk_dir" \
  -DPICOTOOL_NO_LIBUSB=OFF \
  -DPICOTOOL_CODE_OTP=0 \
  -DLIBUSB_INCLUDE_DIR="$libusb_install/include/libusb-1.0" \
  -DLIBUSB_LIBRARIES="$libusb_install/lib/libusb-1.0.a;pthread" \
  -DCMAKE_EXE_LINKER_FLAGS='-static-libstdc++ -static-libgcc'
cmake --build "$work_dir/build/picotool-distribution" --target picotool \
  --parallel "${CMAKE_BUILD_PARALLEL_LEVEL:-4}"
install -m 755 "$work_dir/build/picotool-distribution/picotool" "$output/picotool"

# Fail if a future upstream change adds an unbundled non-system dependency.
readelf -d "$output/picotool" > "$output/dynamic-section.txt"
python3 - "$output/dynamic-section.txt" "$dynamic_loader" <<'PY'
import re
import sys

needed = re.findall(r'Shared library: \[(.*?)\]', open(sys.argv[1]).read())
allowed = {'libc.so.6', 'libm.so.6', sys.argv[2]}
unexpected = set(needed) - allowed
if unexpected:
    raise SystemExit('Unbundled runtime libraries: ' + ', '.join(sorted(unexpected)))
print('Runtime system libraries:', ', '.join(needed))
PY

cp "$libusb_src/COPYING" "$output/licenses/libusb.txt"
cp "$picotool_src/LICENSE.TXT" "$output/licenses/picotool.txt"
cp "$picotool_src/clipp/LICENSE" "$output/licenses/clipp.txt"
cp "$picotool_src/lib/littlefs/LICENSE.md" "$output/licenses/littlefs.txt"
cp "$picotool_src/lib/nlohmann_json/LICENSE.MIT" "$output/licenses/nlohmann-json.txt"
cp "$picotool_src/lib/oofatfs/LICENSE" "$output/licenses/oofatfs.txt"
cp "$sdk_dir/LICENSE.TXT" "$output/licenses/pico-sdk.txt"
cp "$sdk_dir/lib/mbedtls/LICENSE" "$output/licenses/mbedtls.txt"
cp "$picotool_src/udev/60-picotool.rules" "$output/60-picotool.rules"

if [[ $source_bundle == false ]]; then
  cp "$script_dir/build-flasher.sh" "$output/sources/build-flasher.sh"
  cp "$repo_root/docs/rp2350-flasher.md" "$output/README.md"
  cp "$repo_root/docs/rp2350-flasher.md" "$output/sources/README.md"
  cp "$archive" "$output/sources/"
  git -C "$picotool_src" archive --format=tar.gz \
    --prefix="picotool-$picotool_version/" \
    --output="$output/sources/picotool-$picotool_version.tar.gz" HEAD
  git -C "$sdk_dir" archive --format=tar.gz \
    --prefix="pico-sdk-$picotool_version/" \
    --output="$output/sources/pico-sdk-$picotool_version.tar.gz" HEAD
  git -C "$sdk_dir/lib/mbedtls" archive --format=tar.gz \
    --prefix="pico-sdk-$picotool_version/lib/mbedtls/" \
    --output="$output/sources/pico-sdk-mbedtls.tar.gz" HEAD
  {
    printf 'picotool %s %s\n' "$picotool_version" \
      "$(git -C "$picotool_src" rev-parse HEAD)"
    printf 'pico-sdk %s %s\n' "$picotool_version" \
      "$(git -C "$sdk_dir" rev-parse HEAD)"
    printf 'mbedtls %s\n' "$(git -C "$sdk_dir/lib/mbedtls" rev-parse HEAD)"
    printf 'libusb %s %s\n' "$libusb_version" "$libusb_sha256"
  } > "$output/sources/SOURCE-REVISIONS.txt"
  (
    cd "$output/sources"
    sha256sum "libusb-$libusb_version.tar.bz2" \
      "picotool-$picotool_version.tar.gz" \
      "pico-sdk-$picotool_version.tar.gz" \
      pico-sdk-mbedtls.tar.gz > SHA256SUMS
  )
fi

"$output/picotool" version
"$output/picotool" help load >/dev/null
"$output/picotool" help info >/dev/null

if [[ $source_bundle == false ]]; then
  package="$repo_root/build/rp2350-flasher/rp2350-flasher-linux-$architecture.tar.gz"
  tar -czf "$package" -C "$(dirname "$output")" "$(basename "$output")"
  printf '\nFlasher bundle: %s\n' "$package"
else
  printf '\nRebuilt flasher: %s/picotool\n' "$output"
fi
printf 'Build releases on the oldest supported Linux baseline (this build uses the host libc).\n'
