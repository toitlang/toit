// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Tests the interpreter hardening at run time. It patches the operands of the
// bytecodes whose value becomes a code address (LOAD_METHOD's method id and
// the block invoked by INVOKE_BLOCK) to out-of-range values, runs the patched
// snapshot, and checks that the interpreter rejects it with a Toit exception
// (INVALID_PROGRAM) instead of crashing (SIGSEGV, SIGABRT, ...) or jumping to
// an arbitrary byte offset.
//
// The method id read from a block slot or a Lambda_/LazyInitializer_ field is
// validated against the program's method-entry table before the interpreter
// uses it as a code address.
//
// The stack-pointer range checks (LOAD_OUTER & co.) only prevent accesses
// outside the stack; reading the wrong slot of the frame with a small offset
// is not detected at run time, so those opcodes are not patched here.

import expect show *
import host.file
import host.os
import .sandbox-util show *
import ...tools.snapshot show SnapshotBundle ToitMethod

// Signals that mean the interpreter crashed (as opposed to a clean exit or a
// timeout kill).
SIGILL ::= 4
SIGABRT ::= 6
SIGBUS ::= 7
SIGFPE ::= 8
SIGSEGV ::= 11
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

// Cap the number of launched subprocesses to keep the test fast and
// deterministic.
MAX-VARIANTS ::= 120

main args:
  run := args[0]
  compiler := args[1]

  // This test exercises the interpreter's own run-time checks, so the forked
  // toit.run processes must not verify at load, even when the suite is run
  // with TOIT_VERIFY=1.
  os.env["TOIT_VERIFY"] = "0"

  with-tmp-directory: | dir |
    snap := "$dir/prog.snapshot"
    write-file "$dir/prog.toit" PROGRAM
    compile-snapshot compiler "$dir/prog.toit" snap

    // Sanity: the unpatched program runs.
    base := run-process [run, snap] --timeout-ms=20_000
    expect-equals 0 base.exit-code

    // Locate the bytecodes in the snapshot file.
    program := (SnapshotBundle.from-file snap).decode
    bytecodes := program.all-bytecodes
    snapshot-bytes := file.read-contents snap
    blob := find-bytecodes snapshot-bytes bytecodes
    expect blob >= 0

    patched-count := 0
    caught-count := 0
    program.methods.do: | method/ToitMethod |
      method.do-bytecodes: | bytecode index |
        bci := method.absolute-entry-bci + index
        (patch-targets bytecode.name bci).do: | patch/Map |
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
                --message="crash (signal $signal) from patched $bytecode.name at bci $bci"
          if result.output.contains "INVALID_PROGRAM": caught-count++

    print "runtime-hardening: patched $patched-count variants, $caught-count caught, no crashes"
    expect patched-count > 0
    // At least some of the out-of-range operands must be caught by the
    // interpreter's range and method-entry checks.
    expect caught-count > 0

// Returns the list of patch sets for the instruction with the given name at
// the given absolute bci. Each patch set is a map from byte offset (into the
// bytecodes) to the new byte value.
patch-targets name/string bci/int -> List:
  if name == "INVOKE_BLOCK":
    // A large block index reads a block reference from a slot the compiler
    // never put one in; the value is validated before it is used as code.
    return [{(bci + 1): 250}]
  if name == "LOAD_METHOD":
    // Set the 4-byte method id to several out-of-range or unaligned values.
    return [
      {(bci + 1): 0xf0, (bci + 2): 0xff, (bci + 3): 0xff, (bci + 4): 0x7f},
      {(bci + 1): 0x01, (bci + 2): 0x00, (bci + 3): 0x00, (bci + 4): 0x00},
      {(bci + 1): 0x03, (bci + 2): 0x00, (bci + 3): 0x00, (bci + 4): 0x00},
    ]
  return []
