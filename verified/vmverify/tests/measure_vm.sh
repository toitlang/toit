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

# Measures the VM's verifier (TOIT_VERIFY_TIME=1: time per phase and the
# Rust heap high-water mark from vmverify's counting allocator) on format-2
# snapshots, with one or more toit.run binaries, several runs each.
#
# Usage: measure_vm.sh [--runs N] --run TOIT_RUN [--run TOIT_RUN ...] SNAPSHOT...

set -euo pipefail

RUNS=5
BINS=()
SNAPS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --runs) shift; RUNS="$1" ;;
    --run) shift; BINS+=("$1") ;;
    *) SNAPS+=("$1") ;;
  esac
  shift
done

for snap in "${SNAPS[@]}"; do
  for bin in "${BINS[@]}"; do
    for i in $(seq "$RUNS"); do
      line=$(TOIT_VERIFY_TIME=1 "$bin" --verify "$snap" 2>&1 | grep '^verifier' || true)
      echo "$(basename "$snap") $bin: $line"
    done
  done
done
