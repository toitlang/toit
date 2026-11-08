// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Tests the interpreter hardening at run time. It patches the operands of the
// bytecodes whose value becomes a code address (LOAD_METHOD's method id and
// the block invoked by INVOKE_BLOCK) to out-of-range values, runs the patched
// snapshot WITHOUT the verifier, and checks that the interpreter rejects it
// with a Toit exception (INVALID_PROGRAM) instead of crashing (SIGSEGV /
// SIGABRT) or jumping to an arbitrary byte offset.
//
// This is the defense-in-depth layer below the verifier for the "data used as
// a code address" vectors (report 06, 1.1): the method id read from a block
// slot or a Lambda_/LazyInitializer_ field is validated against the program's
// method-entry table before a Method is constructed.
//
// Note: the stack-pointer range checks (LOAD_OUTER & co., report 06 1.2) only
// prevent access outside the stack object; reading the wrong in-frame slot
// (e.g. a return address) with a small offset is the verifier's job, so those
// opcodes are not patched here.

import expect show *
import host.file
import .sandbox-util show *

// Opcode numbers and operand lengths, from src/bytecodes.h.
LOAD-OUTER ::= 5          // 2 bytes: opcode, stack-offset.
STORE-OUTER ::= 6        // 2 bytes.
LOAD-OUTER-BLOCK ::= 39  // 2 bytes.
INVOKE-BLOCK ::= 55      // 2 bytes.
LOAD-METHOD ::= 29       // 5 bytes: opcode, 4-byte method id.

// Signals that mean the interpreter crashed (as opposed to a clean exit or a
// timeout kill).
SIGABRT ::= 6
SIGBUS ::= 7
SIGFPE ::= 8
SIGSEGV ::= 11
SIGILL ::= 4
CRASH-SIGNALS ::= {SIGABRT, SIGBUS, SIGFPE, SIGSEGV, SIGILL}

PROGRAM ::= """
run-blocks x/int [block] -> int:
  sum := 0
  3.repeat: sum += block.call x + it
  return sum

main:
  total := 0
  outer := 7
  2.repeat: | i |
    total += run-blocks i: | v | v + outer + total
  [10, 20, 30].do: | e | total += e
  m := {:}
  5.repeat: m[it] = it * it
  m.do: | k v | total += k + v
  try:
    total += (run-blocks 1: | v | v)
  finally:
    total += outer
  print total
"""

main args:
  run := args[0]
  compiler := args[1]

  with-tmp-directory: | dir |
    snap := "$dir/prog.snapshot"
    write-file "$dir/prog.toit" PROGRAM
    compile-snapshot compiler "$dir/prog.toit" snap

    // Sanity: the program runs and verifies cleanly.
    base := run-process [run, snap] --timeout-ms=20_000
    expect-equals 0 base.exit-code
    v := run-process [run, "--verify", "-q", snap]
    expect-equals 0 v.exit-code

    // Locate the bytecodes in the snapshot file.
    bytecodes-file := "$dir/bytecodes.bin"
    emit := run-process [run, "--verify", "-q", "--emit-bytecodes=$bytecodes-file", snap]
    expect-equals 0 emit.exit-code
    bytecodes := file.read-contents bytecodes-file
    snapshot-bytes := file.read-contents snap
    blob := find-bytecodes snapshot-bytes bytecodes
    expect blob >= 0

    // Only patch real instruction starts (coverage == 1), so we never corrupt
    // a method header (which the verifier, not the interpreter hardening, is
    // responsible for).
    coverage-file := "$dir/coverage.bin"
    cov := run-process [run, "--verify", "-q", "--emit-coverage=$coverage-file", snap]
    expect-equals 0 cov.exit-code
    coverage := file.read-contents coverage-file

    // Cap the number of launched subprocesses to keep the test fast and
    // deterministic.
    MAX-VARIANTS ::= 120
    patched-count := 0
    caught-count := 0
    for i := 0; i < bytecodes.size and patched-count < MAX-VARIANTS; i++:
      if coverage[i] != 1: continue  // Not an instruction start.
      op := bytecodes[i]
      targets := patch-targets op i
      targets.do: | patch |
        if patched-count >= MAX-VARIANTS: continue.do
        patched := snapshot-bytes.copy
        patch.do: | offset value | patched[blob + offset] = value
        out := "$dir/patched.snapshot"
        file.write-contents patched --path=out
        result := run-process [run, out] --timeout-ms=5_000
        patched-count++
        signal := result.exit-signal
        if signal != null:
          expect-not (CRASH-SIGNALS.contains signal)
              --message="crash (signal $signal) from patched $(opcode-name op) at bci $i"
        else if result.output.contains "INVALID_PROGRAM":
          caught-count++

    print "runtime-hardening: patched $patched-count variants, $caught-count rejected with INVALID_PROGRAM, no crashes"
    expect patched-count > 0
    // At least some of the out-of-range operands must be caught as
    // INVALID_PROGRAM (the range / method-entry checks firing).
    expect caught-count > 0
    print "runtime-hardening-test OK"

// Returns the list of patch sets for a hardened opcode at bci, or [] for
// opcodes that are not one of the data-derived-code vectors. Each patch set is
// a map from byte offset (into the bytecodes) to the new byte value.
patch-targets op/int bci/int -> List:
  if op == INVOKE-BLOCK:
    // A large block index reads a block reference from a slot the compiler
    // never put one in; the value is validated before it is used as code.
    return [{(bci + 1): 250}]
  if op == LOAD-METHOD:
    // Set the 4-byte method id to several out-of-range / unaligned values.
    return [
      {(bci + 1): 0xf0, (bci + 2): 0xff, (bci + 3): 0xff, (bci + 4): 0x7f},
      {(bci + 1): 0x01, (bci + 2): 0x00, (bci + 3): 0x00, (bci + 4): 0x00},
      {(bci + 1): 0x03, (bci + 2): 0x00, (bci + 3): 0x00, (bci + 4): 0x00},
    ]
  return []

opcode-name op/int -> string:
  return "opcode $op"
