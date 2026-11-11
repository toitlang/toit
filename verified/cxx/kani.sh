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

# Runs Kani (installed by `verified/cxx/install-tools.sh kani`) on the
# accessor copies of verified/cxx/kani. The build directory is under
# $CXXV_HOME, not in the repository.
# Usage: verified/cxx/kani.sh [KANI OPTIONS...]

set -euo pipefail
. "$(dirname "$0")/env.sh"
export CARGO_HOME=$CXXV_HOME/tools/kani/cargo
export RUSTUP_HOME=$CXXV_HOME/tools/kani/rustup
export KANI_HOME=$CXXV_HOME/tools/kani/home
export CARGO_TARGET_DIR=$CXXV_HOME/kani-target
export PATH=$CXXV_HOME/tools/kani/bin:$CARGO_HOME/bin:$PATH
cd "$(dirname "$0")/kani"
start=$(date +%s.%N)
set +e
cargo kani "$@"
status=$?
set -e
end=$(date +%s.%N)
awk -v s="$start" -v e="$end" -v x="$status" 'BEGIN { printf "wall: %.1f s, exit %d\n", e - s, x }'
exit $status
