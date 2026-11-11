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

# Runs CBMC on one harness with the VM's include paths and defines.
# Usage: verified/cxx/cbmc.sh HARNESS.cc [CBMC OPTIONS...]
# The harnesses use the macros of verified/cxx/harness/cxxv.h, which map to
# __CPROVER_* here (CXXV_CBMC) and to __ESBMC_* under ESBMC.

set -euo pipefail
. "$(dirname "$0")/env.sh"
harness=$1
shift
flags=()
for f in "${CXXV_FLAGS[@]}"; do
  case $f in
    -I*) flags+=(-I "${f#-I}") ;;
    -D*) flags+=(-D "${f#-D}") ;;
  esac
done
start=$(date +%s.%N)
set +e
"$CBMC_BIN/cbmc" "$harness" "${flags[@]}" -D CXXV_CBMC "$@"
status=$?
set -e
end=$(date +%s.%N)
awk -v s="$start" -v e="$end" -v x="$status" 'BEGIN { printf "wall: %.1f s, exit %d\n", e - s, x }'
exit $status
