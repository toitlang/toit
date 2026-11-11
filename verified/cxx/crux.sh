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

# LLVM-level verification with crux-llvm: compiles a harness and one real VM
# source file to bitcode with clang and the VM's flags, links them, and runs
# crux-llvm (Z3 from the opam switch of install-tools.sh framac).
# Usage: verified/cxx/crux.sh HARNESS.cc SOURCE.cc [OPT] [CRUX OPTIONS...]
#   OPT: the optimization level of the VM source (default -Os, the VM's).

set -euo pipefail
. "$(dirname "$0")/env.sh"
harness=$1
source=$2
opt=${3:--Os}
shift 3 || shift $#
out=$CXXV_HOME/crux-out/$(basename "$harness" .cc)$opt
mkdir -p "$out"
# crux-llvm 0.12 parses bitcode up to LLVM 21: the release binaries of
# `install-tools.sh llvm21` (the host clang 23 is too new).
CLANGXX=${CLANGXX:-$CXXV_HOME/tools/llvm21/bin/clang++}
LLVM_LINK=${LLVM_LINK:-$CXXV_HOME/tools/llvm21/bin/llvm-link}
# The VM's flags, with the real C++ library (not the <functional> stand-in
# of the ESBMC harnesses).
vm_flags=(-std=gnu++11 -fno-exceptions -fno-rtti -fno-discard-value-names -g)
for f in "${CXXV_FLAGS[@]}"; do
  [ "$f" = "-I$CXXV_REPO/verified/cxx/include" ] || vm_flags+=("$f")
done
"$CLANGXX" "${vm_flags[@]}" "$opt" -emit-llvm -c "$CXXV_SRC/$source" -o "$out/source.bc"
"$CLANGXX" "${vm_flags[@]}" ${CRUX_HARNESS_FLAGS:-} -O0 -I"$CXXV_HOME/tools/crux/c-src/includes" -emit-llvm -c "$harness" -o "$out/harness.bc"
"$LLVM_LINK" "$out/harness.bc" "$out/source.bc" -o "$out/linked.bc"
export PATH=$CXXV_HOME/tools/opam/root/cxxv/bin:$PATH
start=$(date +%s.%N)
set +e
(cd "$out" && mkdir -p crux-build && "$CXXV_HOME/tools/crux/bin/crux-llvm" --solver=z3 --no-compile --output-directory="$out/results" "$@" linked.bc)
status=$?
set -e
end=$(date +%s.%N)
awk -v s="$start" -v e="$end" -v x="$status" 'BEGIN { printf "wall: %.1f s, exit %d\n", e - s, x }'
exit $status
