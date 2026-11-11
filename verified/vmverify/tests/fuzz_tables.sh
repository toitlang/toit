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

# Fuzzes the launch-time verifier entry point in-process
# (src/bin/toit_vmverify_fuzz.rs) on the verifier input of a few programs:
# compiles them in format 2, saves the VM's verifier input
# (`toit.run --verify --emit-canonical=X.tables`), then runs JOBS fuzz
# processes with different seeds for SECONDS each.
# Usage: fuzz_tables.sh [--seconds N] [--jobs J] [--seed S] [--out DIR] [--certificates [--oom]] [PROGRAM.toit...]
# --certificates: the processes check the mutants with the shipped certificate
# (format/18-shipped-certificate.md), mutating the tables, the certificate or
# both. --oom (with --certificates): each mutant is verified again with
# failing allocations (as on a device with an exhausted heap): it must be
# rejected with OUT_OF_MEMORY, never abort.
# Usage: fuzz_tables.sh [--seconds N] [--jobs J] [--seed S] [--out DIR] [PROGRAM.toit...]
# Programs default to a hello world and a few suite tests. Exit code 1 if
# any process reports a finding (a verifier panic or a slow call).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
BUILD="${BUILD:-$REPO/build/host}"
SECONDS_EACH=60
JOBS=4
SEED=1
OUT="$REPO/build/vmverify-fuzz"
EXTRA=()
PROGRAMS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --seconds) shift; SECONDS_EACH="$1" ;;
    --jobs) shift; JOBS="$1" ;;
    --seed) shift; SEED="$1" ;;
    --out) shift; OUT="$1" ;;
    --certificates) EXTRA+=(--certificates) ;;
    --oom) EXTRA+=(--oom) ;;
    *) PROGRAMS+=("$1") ;;
  esac
  shift
done
mkdir -p "$OUT"
if [ ${#PROGRAMS[@]} -eq 0 ]; then
  printf 'main:\n  print "hello"\n' > "$OUT/hello.toit"
  PROGRAMS=("$OUT/hello.toit" "$REPO/tests/lambda-test.toit" "$REPO/tests/exception-test.toit"
            "$REPO/tests/class-id-test.toit" "$REPO/tests/task-test.toit")
fi
(cd "$HERE/.." && cargo build --release --quiet --bin toit_vmverify_fuzz)
TABLES=()
for p in "${PROGRAMS[@]}"; do
  name="$(basename "$p" .toit)"
  "$BUILD/sdk/lib/toit/bin/toit.compile" -Xbytecode_format=2 -w "$OUT/$name.snapshot" "$p"
  "$BUILD/sdk/lib/toit/bin/toit.run" --verify --emit-canonical="$OUT/$name.tables" "$OUT/$name.snapshot"
  TABLES+=("$OUT/$name.tables")
done
pids=()
for j in $(seq "$JOBS"); do
  "$HERE/../target/release/toit_vmverify_fuzz" --seconds "$SECONDS_EACH" --seed $((SEED + j - 1)) \
      --save "$OUT/findings" ${EXTRA[@]+"${EXTRA[@]}"} "${TABLES[@]}" > "$OUT/fuzz-$((SEED + j - 1)).log" 2>&1 &
  pids+=($!)
done
status=0
for pid in "${pids[@]}"; do
  wait "$pid" || status=1
done
grep -h '^seed\|^FINDING\|^baseline' "$OUT"/fuzz-*.log | sort | uniq
exit $status
