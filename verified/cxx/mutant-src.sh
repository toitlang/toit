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

# Makes a copy of src/ with one known bug put back (the reverse of the
# commit that fixed it, verified/cxx/mutants/NAME.patch) under
# $CXXV_HOME/mutant-src/NAME and prints its path. The harnesses then run on
# it with CXXV_SRC=<that path> (verified/cxx/run.sh --mutants).
# Usage: verified/cxx/mutant-src.sh NAME

set -euo pipefail
. "$(dirname "$0")/env.sh"
name=$1
dir=$CXXV_HOME/mutant-src/$name
rm -rf "$dir"
mkdir -p "$dir"
cp -r "$CXXV_REPO/src" "$dir/src"
patch -s -d "$dir" -p1 < "$CXXV_REPO/verified/cxx/mutants/$name.patch"
echo "$dir/src"
