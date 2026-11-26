#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Regenerates patches/esp-idf-dict-log.patch from the overlay's copies of
# components/esp_common and components/log (edited in place) against the
# shared checkout. Apply with `patch -p1` in an ESP-IDF tree.
set -euo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a761e44286b8f7807
A=/home/flo/work/opentoit-sandbox-artifacts/check-messages
S=/home/flo/work/opentoit-sandbox/third_party/esp-idf
O=$WT/build/idf-overlay/esp-idf
P=$A/patches/esp-idf-dict-log.patch
: > "$P"
for c in esp_common log; do
  (cd "$S" && diff -ruN "components/$c" "$O/components/$c" || true) \
    | sed -e "s#^--- components/#--- a/components/#" -e "s#^+++ $O/components/#+++ b/components/#" \
          -e "s#^diff -ruN components/\(\S*\) $O/components/\(\S*\)#diff -ruN a/components/\1 b/components/\2#" \
          -e "s#^\(---\|+++\) \(\S*\)\t.*#\1 \2#" >> "$P"
done
grep -c "" "$P"
