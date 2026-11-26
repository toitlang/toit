#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Creates a private ESP-IDF tree for the check-messages builds without
# touching the shared checkout (/home/flo/work/opentoit-sandbox/third_party/esp-idf):
# every top-level entry and every component is a symbolic link to the
# shared checkout, except components/esp_common and components/log, which
# are real copies with patches/esp-idf-dict-log.patch applied.
# The tree has no .git; ESP-IDF takes its version from version.txt, which
# holds the string the shared checkout's builds get from `git describe`.
# Usage: idf-overlay.sh [--no-patch]   (prints the overlay's IDF_PATH)
set -euo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a761e44286b8f7807
A=/home/flo/work/opentoit-sandbox-artifacts/check-messages
SHARED=/home/flo/work/opentoit-sandbox/third_party/esp-idf
O=$WT/build/idf-overlay/esp-idf
PATCH=1
[ "${1:-}" = --no-patch ] && PATCH=0
rm -rf "$O"
mkdir -p "$O/components"
for e in "$SHARED"/* "$SHARED"/.[!.]*; do
  n=$(basename "$e")
  case $n in
    components|.git|tools) ;;
    *) ln -s "$e" "$O/$n" ;;
  esac
done
# tools and tools/cmake are real directories: tools/cmake/idf.cmake infers the
# ESP-IDF directory from its own (resolved) location.
mkdir -p "$O/tools/cmake"
for e in "$SHARED"/tools/* "$SHARED"/tools/.[!.]*; do
  [ "$(basename "$e")" = cmake ] || ln -s "$e" "$O/tools/"
done
for e in "$SHARED"/tools/cmake/*; do ln -s "$e" "$O/tools/cmake/"; done
for c in "$SHARED"/components/*; do
  n=$(basename "$c")
  case $n in
    esp_common|log) cp -r "$c" "$O/components/$n" ;;
    *) ln -s "$c" "$O/components/$n" ;;
  esac
done
# The version string of the shared checkout's builds (git describe there).
echo "v5.2-dev-13503-g8a8b4a72ce-dirty" > "$O/version.txt"
if [ $PATCH = 1 ]; then
  patch -d "$O" -p1 --no-backup-if-mismatch < "$A/patches/esp-idf-dict-log.patch" > /dev/null
fi
echo "$O"
