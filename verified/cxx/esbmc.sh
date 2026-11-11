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

# Runs ESBMC on one harness with the VM's include paths and defines.
# Usage: verified/cxx/esbmc.sh HARNESS.cc [ESBMC OPTIONS...]
#

set -euo pipefail
. "$(dirname "$0")/env.sh"
# Cap the memory of a run (default 12 GB, CXXV_MEM_GB): a harness with too
# large bounds then fails instead of exhausting the machine.
ulimit -v $(( ${CXXV_MEM_GB:-12} * 1024 * 1024 ))
harness=$1
shift

# Mechanical extracts of single functions from VM sources the tool cannot
# take whole (tool defect T3: ESBMC 8.6 crashes converting
# src/objects_runtime.cc). The text is the source's, unchanged, from the
# function's first line to the next line that is a lone "}".
gen=$CXXV_HOME/gen/$(echo "$CXXV_SRC" | md5sum | cut -c1-12)
mkdir -p "$gen"
extract() {  # extract SOURCE FIRST-LINE-PREFIX OUT
  awk -v first="$2" 'index($0, first) == 1 { on = 1 } on { print } on && $0 == "}" { exit }' \
    "$CXXV_SRC/$1" > "$gen/$3"
  [ -s "$gen/$3" ] || { echo "esbmc.sh: cannot extract $2 from $1"; exit 6; }
}
extract objects_runtime.cc "void Stack::v2_copy_to(Stack* other) {" v2_copy_to.inc
extract objects_runtime.cc "bool Object::mutable_byte_content(Process* process, uint8** content, word* length, Error** error) {" mbc4.inc
extract objects_runtime.cc "bool Object::mutable_byte_content(Process* process, uint8** content, word* length, Error** error, int depth) {" mbc5.inc
extract objects_runtime.cc "bool Object::mutable_byte_content(Process* process, MutableBlob* blob, Error** error) {" mbc_blob.inc

common=("$harness" "${CXXV_FLAGS[@]}" -I"$CXXV_REPO/verified/cxx/harness" -I"$gen" --std c++11)

start=$(date +%s.%N)
set +e
"$ESBMC" "${common[@]}" "$@"
status=$?
set -e
end=$(date +%s.%N)
awk -v s="$start" -v e="$end" -v x="$status" 'BEGIN { printf "wall: %.1f s, exit %d\n", e - s, x }'
exit $status
