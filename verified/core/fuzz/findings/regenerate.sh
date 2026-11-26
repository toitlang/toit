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

# Rebuilds the reproducers of the fuzz findings in the current bytecode
# format. The verifier findings (infer-panic-*, r5-*, task-stack-field-store): each is a test program compiled for the
# verified core (untrusted) with one method body replaced by tools/asm.toit
# so that it contains the malformed construct of the original finding (the
# .txt next to each snapshot: the original mutation and outcome, and what
# the rebuilt image contains). A control image with a well-formed body in
# the same method must verify, so that the rejection is the construct's.
# Run after a change of the image format (tag, method table, certificate
# header); verified/vmverify/tests/findings.sh checks the results.
#
# Usage: regenerate.sh [SDK]     (default: build/host/sdk of the repository)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
SDK="${1:-$REPO/build/host/sdk}"
BIN="$SDK/lib/toit/bin"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

compile() {  # test-name out
  (cd "$REPO" && TOIT_BYTECODE_FORMAT=2 "$BIN/toit.compile" --untrusted -w "$2" "tests/$1.toit")
}

patch() {  # base out method asm
  (cd "$REPO" && "$BIN/toit.run" --project-root tools tools/asm.toit patch "$1" "$2" "$3" "$4") \
    2>&1 | grep -v "always evaluates" || true
  [ -f "$2" ] || { echo "asm patch failed for $2" >&2; exit 1; }
}

expect() {  # verdict snapshot
  local out
  out="$("$BIN/toit.run" --verify "$2" 2>&1 || true)"
  if ! grep -q "^$1" <<< "$(tail -1 <<< "$out")"; then
    echo "$(basename "$2"): expected $1, got:" >&2
    echo "$out" | tail -3 >&2
    exit 1
  fi
}

compile map-test "$WORK/map-test.snapshot"
compile task-test "$WORK/task-test.snapshot"
compile list-test "$WORK/list-test.snapshot"

# infer-panic-dispatch-target: an INVOKE_STATIC whose dispatch entry is not
# a method (the index lies past the dispatch table).
patch "$WORK/map-test.snapshot" "$WORK/control-dispatch.snapshot" main "RETURN_NULL"
expect VERIFIED "$WORK/control-dispatch.snapshot"
patch "$WORK/map-test.snapshot" "$HERE/infer-panic-dispatch-target.snapshot" main \
  "INVOKE_STATIC 65535; POP_1; RETURN_NULL"

# infer-panic-empty-body: a method without a single valid instruction. An
# empty body (the original construct) no longer reaches the verifier: the
# VM's method-table computation refuses it first ("format-2 program
# rejected: empty method body", src/v2_validate_records.h). The nearest
# construct the verifier sees is a body of one byte that is no opcode
# (asm.toit pads an emptied odd-length body with 0xff to keep the parity of
# the following entries, format note 21): the verifier rejects it at the
# method's first offset, where the empty body made the inference index an
# empty map.
patch "$WORK/task-test.snapshot" "$WORK/control-empty.snapshot" initialize-entry-task_ "RETURN_NULL"
expect VERIFIED "$WORK/control-empty.snapshot"
patch "$WORK/task-test.snapshot" "$HERE/infer-panic-empty-body.snapshot" initialize-entry-task_ ""

# r5-load-task-stack-field: a Task_ method reads field 0 of its receiver
# (the task's Stack, Task::STACK_INDEX).
patch "$WORK/list-test.snapshot" "$WORK/control-load.snapshot" initialize-entry-task_ \
  "LOAD_FIELD_THIS 5; POP_1; RETURN_NULL"
expect VERIFIED "$WORK/control-load.snapshot"
patch "$WORK/list-test.snapshot" "$HERE/r5-load-task-stack-field.snapshot" initialize-entry-task_ \
  "LOAD_FIELD_THIS 0; POP_1; RETURN_NULL"

# r5-store-task-id-field: a Task_ method writes field 1 of its receiver
# (the task's id).
patch "$WORK/task-test.snapshot" "$WORK/control-store.snapshot" initialize-entry-task_ \
  "LOAD_SMI_0; STORE_FIELD_THIS 5; POP_1; RETURN_NULL"
expect VERIFIED "$WORK/control-store.snapshot"
patch "$WORK/task-test.snapshot" "$HERE/r5-store-task-id-field.snapshot" initialize-entry-task_ \
  "LOAD_SMI_0; STORE_FIELD_THIS 1; POP_1; RETURN_NULL"

# task-stack-field-store (launch fuzz 2026-11-10, R5): a Task_ method
# overwrites field 0 of its receiver (the task's Stack).
patch "$WORK/task-test.snapshot" "$HERE/task-stack-field-store.snapshot" initialize-entry-task_ \
  "LOAD_SMI_0; STORE_FIELD_THIS 0; POP_1; RETURN_NULL"

# Source reproducers of runtime findings: well-typed programs the verifier
# accepts (the bugs were in C++ primitives they call).
(cd "$HERE" && TOIT_BYTECODE_FORMAT=2 "$BIN/toit.compile" --untrusted \
  -w "$HERE/encoder-cyclic-array-stack-overflow.snapshot" encoder-cyclic-array.toit)
(cd "$HERE" && TOIT_BYTECODE_FORMAT=2 "$BIN/toit.compile" --untrusted \
  -w "$HERE/task-receive-message-null.snapshot" task-receive-message-null.toit)
expect VERIFIED "$HERE/encoder-cyclic-array-stack-overflow.snapshot"
expect VERIFIED "$HERE/task-receive-message-null.snapshot"

for f in infer-panic-dispatch-target infer-panic-empty-body r5-load-task-stack-field r5-store-task-id-field \
    task-stack-field-store; do
  expect REJECTED "$HERE/$f.snapshot"
  echo "$f: $("$BIN/toit.run" --verify "$HERE/$f.snapshot" 2>&1 | grep -v '^REJECTED' | tail -1)"
done
