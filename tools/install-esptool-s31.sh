#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
set -euo pipefail
if [[ $# -ne 1 ]]; then
  echo "usage: $0 SDK-DIRECTORY" >&2
  exit 1
fi
version=5.5.0
extension=""
archive_extension=tar.gz
case "$(uname -s)/$(uname -m)" in
  Linux/x86_64)
    arch=linux-amd64
    checksum=ff76c56cb51cf29109558ceb61754adcbe9cc5107b2750d41b00be85cf003069 ;;
  Linux/aarch64|Linux/arm64)
    arch=linux-aarch64
    checksum=3e7654b320febdb558eb07c53360acab6897ccc5ecd5d8b68ab36e6b78922188 ;;
  Linux/armv7l)
    arch=linux-armv7
    checksum=046ea35d7a4504713fa493ca615b53649a822c3cd391dbaaccdf2dfc43d16497 ;;
  Darwin/x86_64)
    arch=macos-amd64
    checksum=ed3f24d02c8380f6685f46ef9f9e135f80adb09f50055d8db16b578617bb5d9d ;;
  Darwin/arm64|Darwin/aarch64)
    arch=macos-arm64
    checksum=8652bec3712d746b7df7e9a495270fffa0df3b1e7e99016fd69b88772d4d56d4 ;;
  MINGW*/x86_64|MSYS*/x86_64|CYGWIN*/x86_64)
    arch=windows-amd64
    checksum=e7142a6b6714173b8337e6044984198344c5da31341b333f3d89a59ed8d1ea57
    extension=.exe
    archive_extension=zip ;;
  Linux/riscv64)
    echo "No upstream S31 esptool binary for riscv64; use ESPTOOL_PATH with esptool >= $version." >&2
    exit 0 ;;
  *) echo "Unsupported S31 esptool platform: $(uname -s)/$(uname -m)" >&2; exit 1 ;;
esac
target_dir="$1/lib/toit/bin"
target="$target_dir/esptool-s31$extension"
if [[ -x "$target" && $("$target" version 2>/dev/null || true) == *"esptool v$version"* ]]; then
  echo "S31 esptool $version is already installed in $1"
  exit 0
fi
tmp="$(mktemp -d "${TMPDIR:-/tmp}/toit-esptool-s31.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
archive="esptool-v$version-$arch.$archive_extension"
curl --location --fail --output "$tmp/$archive" "https://github.com/espressif/esptool/releases/download/v$version/$archive"
python3 - "$tmp/$archive" "$checksum" <<'PY'
import hashlib, pathlib, sys
if hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest() != sys.argv[2]:
    sys.exit('S31 esptool archive checksum mismatch')
PY
if [[ "$archive_extension" == zip ]]; then
  unzip -q "$tmp/$archive" -d "$tmp"
else
  tar -xzf "$tmp/$archive" -C "$tmp"
fi
mkdir -p "$target_dir"
cp "$tmp/esptool-$arch/esptool$extension" "$target"
cp "$tmp/esptool-$arch/LICENSE" "$target_dir/LICENSE.esptool-s31"
chmod +x "$target"
