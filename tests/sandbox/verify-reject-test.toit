// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Tests the structural bytecode verifier: it accepts valid programs, prints
// the referenced primitives, rejects corrupted bytecodes, rejects HALT 2/3
// and zero-offset branches in untrusted programs, and never crashes on
// single-byte mutations.

import expect show *
import host.file
import .sandbox-util show *

// Opcode numbers, from src/bytecodes.h. Only used to locate a branch in the
// emitted bytecodes; if the enum changes, the branch-patch check is skipped.
BRANCH ::= 81
BRANCH-IF-TRUE ::= 82
BRANCH-IF-FALSE ::= 83

VALID-PROGRAM ::= """
class Point:
  x := 0
  y := 0
  len-sq -> int: return x * x + y * y

fib n/int -> int:
  if n < 2: return n
  return (fib n - 1) + (fib n - 2)

main:
  p := Point
  p.x = 3
  p.y = 4
  sum := 0
  10.repeat: sum += it
  list := [1, 2, 3]
  list.do: sum += it
  m := {:}
  m["a"] = 1
  try:
    sum += fib 5
  finally:
    sum += p.len-sq
  print sum
  print m["a"]
"""

DEEP-SLEEP-PROGRAM ::= """
main:
  __deep-sleep__ 10
"""

verify run/string snap/string args/List -> RunResult:
  return run-process ([run, "--verify"] + args + [snap])

main args:
  run := args[0]
  compiler := args[1]

  with-tmp-directory: | dir |
    valid := "$dir/valid.snapshot"
    write-file "$dir/valid.toit" VALID-PROGRAM
    compile-snapshot compiler "$dir/valid.toit" valid

    // A valid program is accepted.
    result := verify run valid ["-q"]
    expect-equals 0 result.exit-code
    expect (result.output.contains "VERIFIED")

    // The verifier emits the referenced-primitive set.
    result = verify run valid ["-q", "--primitives"]
    expect-equals 0 result.exit-code
    expect (result.output.contains "primitives ")
    expect (result.output.contains "core.")

    // A corrupted byte inside the bytecodes is rejected.
    result = verify run valid ["-q", "--corrupt=0:200"]
    expect-equals 1 result.exit-code
    expect (result.output.contains "REJECTED")

    // Deep sleep (HALT 2) is rejected for untrusted programs but accepted
    // for trusted ones.
    sleep-snap := "$dir/deep-sleep.snapshot"
    write-file "$dir/deep-sleep.toit" DEEP-SLEEP-PROGRAM
    compile-snapshot compiler "$dir/deep-sleep.toit" sleep-snap

    result = verify run sleep-snap ["-q"]
    expect-equals 1 result.exit-code
    expect (result.output.contains "HALT 2")
    expect (result.output.contains "deep sleep")

    result = verify run sleep-snap ["-q", "--trusted"]
    expect-equals 0 result.exit-code
    expect (result.output.contains "VERIFIED")

    // A zero-offset forward branch is rejected.
    test-zero-offset-branch run valid dir

    // Single-byte mutations never crash the verifier, and the overwhelming
    // majority are rejected (the ones that survive change the program's
    // meaning, not the invariants the verifier protects).
    result = verify run valid ["-q", "--fuzz=1500"]
    expect-equals 0 result.exit-code
    expect (result.output.contains "fuzz: 1500 mutations")
    rejected := extract-int result.output "mutations, " " rejected"
    accepted := extract-int result.output "rejected, " " accepted"
    print "fuzz: $rejected rejected, $accepted accepted"
    expect rejected > accepted

    print "verify-reject-test OK"

// Finds a branch in the emitted bytecodes of the valid program, sets its
// 16-bit offset to zero in a copy of the snapshot, and checks that the
// verifier rejects the zero-offset branch.
test-zero-offset-branch run/string snap/string dir/string -> none:
  bytecodes-file := "$dir/bytecodes.bin"
  result := verify run snap ["-q", "--emit-bytecodes=$bytecodes-file"]
  expect-equals 0 result.exit-code
  bytecodes := file.read-contents bytecodes-file
  snapshot-bytes := file.read-contents snap
  blob-offset := find-bytecodes snapshot-bytes bytecodes
  expect blob-offset >= 0

  // Scan for a forward branch with a non-zero offset.
  branch-bci := -1
  for i := 0; i < bytecodes.size - 3; i++:
    op := bytecodes[i]
    if op == BRANCH or op == BRANCH-IF-TRUE or op == BRANCH-IF-FALSE:
      offset := bytecodes[i + 1] | (bytecodes[i + 2] << 8)
      if offset != 0:
        branch-bci = i
        break
  if branch-bci < 0:
    print "test-zero-offset-branch: no branch found (opcode numbers changed?), skipping"
    return

  patched := snapshot-bytes.copy
  patched[blob-offset + branch-bci + 1] = 0
  patched[blob-offset + branch-bci + 2] = 0
  patched-snap := "$dir/zero-branch.snapshot"
  file.write-contents patched --path=patched-snap

  r := verify run patched-snap ["-q"]
  expect-equals 1 r.exit-code
  expect (r.output.contains "zero offset")
  print "zero-offset branch rejected"

extract-int text/string before/string after/string -> int:
  start := text.index-of before
  if start < 0: return -1
  start += before.size
  end := text.index-of after start
  if end < 0: return -1
  return int.parse text[start..end]
