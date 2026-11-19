#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
set -euo pipefail
if [[ $# -gt 1 || (${1:-} != "" && ${1:-} != "--install") ]]; then
  echo "usage: $0 [--install]" >&2
  exit 1
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
git -C "$root" submodule update --init --recursive -- third_party/esp-idf-s31
if [[ ${1:-} == --install ]]; then
  export IDF_PATH="$root/third_party/esp-idf-s31"
  export IDF_TOOLS_PATH="${TOIT_S31_IDF_TOOLS_PATH:-$HOME/.espressif-s31}"
  python3 "$IDF_PATH/tools/idf_tools.py" install --targets=esp32s31
  python3 "$IDF_PATH/tools/idf_tools.py" install-python-env
fi
