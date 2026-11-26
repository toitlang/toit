#!/usr/bin/env bash
# Compiles an IR file with an llc build and prints the assembly without
# directives. Usage: llc-show.sh <llc-build-dir> <file.ll> [llc args]
set -euo pipefail
LLC_DIR=$1
F=$2
shift 2
"$LLC_DIR/bin/llc" -mtriple=xtensa -mcpu=esp32 "$@" "$F" -o - \
  | grep -v -E '^\s*\.(p2align|type|size|cfi_|file|section|globl|literal_position|text)|^\.Lfunc_end|^\s*#|^\s*$|Begin function'
