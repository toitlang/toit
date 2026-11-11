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

# Runs Frama-C/WP (installed by `install-tools.sh framac`) with runtime-error
# annotations on a C file of verified/cxx/framac.
# Usage: verified/cxx/framac.sh FILE.c [FRAMA-C OPTIONS...]

set -euo pipefail
. "$(dirname "$0")/env.sh"
export OPAMROOT=$CXXV_HOME/tools/opam/root
export PATH=$OPAMROOT/cxxv/bin:$PATH
file=$1
shift
why3 config detect > /dev/null 2>&1 || true
start=$(date +%s.%N)
set +e
frama-c -wp -wp-rte -wp-prover alt-ergo,z3 -wp-timeout 30 -wp-par 8 \
  -wp-session "$CXXV_HOME/framac-session/$(basename "$file" .c)" "$@" "$file"
status=$?
set -e
end=$(date +%s.%N)
awk -v s="$start" -v e="$end" -v x="$status" 'BEGIN { printf "wall: %.1f s, exit %d\n", e - s, x }'
exit $status
