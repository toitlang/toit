#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; version
# 2.1 only.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# The license can be found in the file `LICENSE` in the top level
# directory of this repository.

# Experimental (TOIT_VM_CLANG in this component's CMakeLists.txt): compiles
# one source of the VM with Espressif's clang instead of ESP-IDF's GCC. Used
# as the CMake compiler launcher of the toit_vm target, so it receives the
# GCC command line that ESP-IDF built and rewrites it:
#
# - the compiler becomes clang/clang++ of CLANG-BIN-DIR, with the target
#   and CPU of the GCC (xtensa-esp32-elf-*, xtensa-esp32s3-elf-*,
#   riscv32-esp-elf-*);
# - the headers are GCC's (its libstdc++ and newlib include directories,
#   not its own built-in headers), so the VM is compiled against the same
#   C and C++ library headers as the rest of the firmware, which links
#   GCC's libstdc++ and newlib;
# - -fshort-wchar: GCC's wchar_t is 16 bits on these targets, clang's 32;
# - Xtensa: constructors in .ctors, as GCC (-fno-use-init-array), and no
#   frame pointer (-fomit-frame-pointer, see below);
# - GCC options that clang does not have are dropped (the list below), and
#   TOIT_VM_CLANG_OPT (environment, for example -Oz) replaces -Os;
# - ccache is used when it is on the PATH.
#
# Usage: clang-launcher.sh CLANG-BIN-DIR CACHE-DIR GCC-COMPILER ARGS...

set -eu

CLANG_DIR=$1
CACHE_DIR=$2
GCC=$3
shift 3

case $GCC in
  *++) CLANG=$CLANG_DIR/clang++; LANG_KIND=c++ ;;
  *) CLANG=$CLANG_DIR/clang; LANG_KIND=c ;;
esac
case ${GCC##*/} in
  xtensa-esp32-elf-*) TARGET_ARGS=(--target=xtensa-esp-elf -mcpu=esp32) ;;
  xtensa-esp32s2-elf-*) TARGET_ARGS=(--target=xtensa-esp-elf -mcpu=esp32s2) ;;
  xtensa-esp32s3-elf-*) TARGET_ARGS=(--target=xtensa-esp-elf -mcpu=esp32s3) ;;
  riscv32-esp-elf-*) TARGET_ARGS=(--target=riscv32-esp-elf) ;;
  *) echo "clang-launcher.sh: unknown compiler $GCC" >&2; exit 1 ;;
esac
# ESP-IDF's Xtensa linker scripts run the constructors of .ctors only (its
# GCC emits .ctors); clang 22 emits .init_array by default, which the
# linker then drops as unused: the static constructors never run.
# clang keeps a frame pointer by default on Xtensa; in such a function a
# call with arguments on the stack moves SP by their size rounded to 4
# only (espressif/llvm-project#142), so the callee runs with SP not 16-byte
# aligned. Without the frame pointer the outgoing arguments are in the
# fixed frame and SP does not move (and a7 is free; GCC has none either).
case ${GCC##*/} in xtensa-*) TARGET_ARGS+=(-fno-use-init-array -fomit-frame-pointer) ;; esac

# The options that select GCC's multilib (and so its include directories).
MULTILIB_ARGS=()
ARGS=()
for a in "$@"; do
  case $a in
    # GCC options without a clang equivalent.
    -fstrict-volatile-bitfields|-fno-tree-switch-conversion|-ftree-switch-conversion) ;;
    -fno-crossjumping|-fno-tree-tail-merge|-freorder-blocks|-fno-shrink-wrap) ;;
    -Wno-old-style-declaration|-fanalyzer|-mlongcalls) ;;
    -Os)
      ARGS+=("${TOIT_VM_CLANG_OPT:--Os}")
      ;;
    -march=*|-mabi=*|-fno-rtti|-mfix-esp32-psram-cache-issue|-mfix-esp32-psram-cache-strategy=*)
      MULTILIB_ARGS+=("$a")
      ARGS+=("$a")
      ;;
    *) ARGS+=("$a") ;;
  esac
done

# GCC's include directories for this multilib and language, cached.
key=$(printf '%s\n' "$GCC" "$LANG_KIND" "${MULTILIB_ARGS[@]+"${MULTILIB_ARGS[@]}"}" | md5sum | cut -c1-16)
RSP=$CACHE_DIR/includes-$key.rsp
if [ ! -f "$RSP" ]; then
  mkdir -p "$CACHE_DIR"
  tmp=$(mktemp "$CACHE_DIR/includes.XXXXXX")
  {
    echo "-nostdlibinc"
    "$GCC" "${MULTILIB_ARGS[@]+"${MULTILIB_ARGS[@]}"}" -x "$LANG_KIND" -E -v /dev/null 2>&1 > /dev/null |
      sed -n '/^#include <\.\.\.> search starts here:/,/^End of search list\./p' |
      sed -e '1d' -e '$d' -e 's/^ *//' |
      while read -r dir; do
        dir=$(cd "$dir" && pwd)
        # GCC's own built-in headers (stddef.h, stdarg.h, ...) are replaced
        # by clang's.
        case $dir in */lib/gcc/*/include|*/lib/gcc/*/include-fixed) continue ;; esac
        echo "-isystem"
        echo "$dir"
      done
  } > "$tmp"
  mv "$tmp" "$RSP"
fi

LAUNCH=()
if command -v ccache > /dev/null 2>&1 && [ "${TOIT_VM_CLANG_CCACHE:-1}" = 1 ]; then
  LAUNCH=(ccache)
fi
# Diagnostics clang has in -Wall/-Werror=all and GCC has not (as in
# CMakeLists.txt for IDF_TOOLCHAIN=clang): empty structs in ESP-IDF's
# extern "C" headers, unused private fields, the one variable-length array,
# ESP-IDF's DPORT register macros (they redeclare one function with
# different error attributes; clang keeps the first).
WARNING_ARGS=(-Wno-extern-c-compat -Wno-error=unused-private-field -Wno-vla-cxx-extension
  -Wno-ignored-attributes)
exec "${LAUNCH[@]+"${LAUNCH[@]}"}" "$CLANG" "${TARGET_ARGS[@]}" -fshort-wchar "@$RSP" "${ARGS[@]}" "${WARNING_ARGS[@]}" ${TOIT_VM_CLANG_FLAGS:-}
