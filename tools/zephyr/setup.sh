#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the LGPL-2.1 license in LICENSE.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
workspace="$root/.cache/zephyr-workspace"
venv="$root/.cache/zephyr-venv"
revision=1f6485eca25431b5ff27ce9a754218c9e559bbbb # Zephyr v4.4.1.
mkdir -p "$workspace"
if [[ ! -d "$workspace/zephyr" ]]; then
  git init -q "$workspace/zephyr"
  git -C "$workspace/zephyr" remote add origin https://github.com/zephyrproject-rtos/zephyr.git
  git -C "$workspace/zephyr" fetch --depth 1 origin "$revision"
  git -C "$workspace/zephyr" checkout --detach FETCH_HEAD
fi
[[ "$(git -C "$workspace/zephyr" rev-parse HEAD)" == "$revision" ]] || {
  echo "Unexpected Zephyr revision; expected $revision" >&2
  exit 1
}
patch="$root/tools/zephyr/patches/spi-dynamic-cs.patch"
security_patch="$root/tools/zephyr/patches/smp-h8-selftest-endian.patch"
git -C "$workspace/zephyr" diff --cached --quiet || {
  echo "Zephyr has staged modifications" >&2
  exit 1
}
# Accept the clean checkout, the previous SPI-only setup, or exactly both
# versioned patches. Reject unrelated changes before modifying the checkout.
patch_state=$(mktemp -d)
trap 'rm -rf -- "$patch_state"' EXIT
cat "$patch" "$security_patch" > "$patch_state/expected"
git -C "$workspace/zephyr" diff --binary --full-index --no-ext-diff --no-textconv \
  --no-color --src-prefix=a/ --dst-prefix=b/ --unified=3 > "$patch_state/actual"
if cmp -s "$patch_state/actual" "$patch_state/expected"; then
  :
elif cmp -s "$patch_state/actual" "$patch"; then
  git -C "$workspace/zephyr" apply --check "$security_patch"
  git -C "$workspace/zephyr" apply "$security_patch"
elif [[ ! -s "$patch_state/actual" ]]; then
  git -C "$workspace/zephyr" apply --check "$patch" "$security_patch"
  git -C "$workspace/zephyr" apply "$patch" "$security_patch"
else
  echo "Zephyr differs from the pinned revision plus the supported patches" >&2
  exit 1
fi
git -C "$workspace/zephyr" diff --binary --full-index --no-ext-diff --no-textconv \
  --no-color --src-prefix=a/ --dst-prefix=b/ --unified=3 | cmp -s - "$patch_state/expected" || {
  echo "Zephyr patch verification failed" >&2
  exit 1
}
if [[ ! -x "$venv/bin/python" ]]; then
  python3 -m venv "$venv"
fi
"$venv/bin/python" -m pip install west==1.5.0 -r "$workspace/zephyr/scripts/requirements-base.txt"
cd "$workspace"
if [[ ! -d .west ]]; then
  "$venv/bin/west" init -l zephyr
fi
# Includes OpenAMP for HCI and the official custom-PSA-provider Kconfig
# definitions. The latter module's library is not linked alongside Toit's
# Mbed TLS. Their revisions are pinned by Zephyr's west.yml.
"$venv/bin/west" update --narrow -o=--depth=1 cmsis cmsis_6 hal_nordic libmetal open-amp mbedtls
