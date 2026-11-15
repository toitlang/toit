#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the LGPL-2.1 license in LICENSE.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
actual=$(mktemp)
trap 'rm -f -- "$actual"' EXIT
git grep --no-line-number -w TOIT_FREERTOS -- src | LC_ALL=C sort > "$actual"
if ! diff -u tools/freertos-guards.allowlist "$actual"; then
  echo "New or changed TOIT_FREERTOS use: generic embedded code uses TOIT_EMBEDDED." >&2
  echo "Update the allowlist only after reviewing a genuinely FreeRTOS-specific dependency." >&2
  exit 1
fi
