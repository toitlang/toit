// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Tests that the interpreter checks the field accesses of untrusted programs
// at run time, in every build. It patches the field index of the LOAD_FIELD
// and STORE_FIELD instructions of a method to a value past the end of the
// instance, runs the patched snapshot as an untrusted program, and checks
// that the access throws INVALID_PROGRAM instead of reading or writing past
// the end of the object.
//
// The checks are the format-1 interpreter's (untrusted format-1 programs run
// with a separate dispatch table). Untrusted programs must be in format 2
// by default, so the test compiles in format 1 and allows untrusted format 1
// (TOIT_UNTRUSTED_FORMAT1=1), also when the suite runs with
// TOIT_BYTECODE_FORMAT=2. Format 2 runs field accesses on the verified
// core, which the fuzz harness covers (verified/core/fuzz).

import expect show *
import host.file
import host.os
import .sandbox-util show *

// Opcode numbers, from src/bytecodes.h.
LOAD-FIELD ::= 7         // 2 bytes: opcode, field index.
STORE-FIELD ::= 11       // 2 bytes.
STORE-FIELD-POP ::= 13   // 2 bytes.

FIELD-COUNT ::= 40
// No class of the core libraries has that many fields, so the operand
// identifies the accesses of the test class.
LAST-FIELD ::= FIELD-COUNT - 1
PATCHED-FIELD ::= 250

// Signals that mean the interpreter crashed.
CRASH-SIGNALS ::= {4, 6, 7, 8, 11}

program-source -> string:
  source := "class Big:\n"
  FIELD-COUNT.repeat: source += "  f$it := 0\n"
  source += "  peek -> int: return f$LAST-FIELD + 1\n"
  source += "  poke v/int -> none: f$LAST-FIELD = v * 2\n"
  source += "\n"
  source += "main:\n"
  source += "  big := Big\n"
  source += "  big.poke 20\n"
  source += "  print \"value: \$big.peek\"\n"
  return source

main args:
  run := args[0]
  compiler := args[1]
  os.env["TOIT_BYTECODE_FORMAT"] = "1"
  os.env["TOIT_UNTRUSTED_FORMAT1"] = "1"

  with-tmp-directory: | dir |
    snap := "$dir/prog.snapshot"
    write-file "$dir/prog.toit" program-source
    compile-snapshot compiler "$dir/prog.toit" snap

    // The unmodified program runs as an untrusted program.
    base := run-process [run, "--untrusted", snap] --timeout-ms=20_000
    if base.exit-code != 0: print base.output
    expect-equals 0 base.exit-code
    expect (base.output.contains "value: 41")

    bytecodes-file := "$dir/bytecodes.bin"
    coverage-file := "$dir/coverage.bin"
    emit := run-process [run, "--verify", "-q", "--emit-bytecodes=$bytecodes-file", snap]
    expect-equals 0 emit.exit-code
    emit = run-process [run, "--verify", "-q", "--emit-coverage=$coverage-file", snap]
    expect-equals 0 emit.exit-code
    bytecodes := file.read-contents bytecodes-file
    coverage := file.read-contents coverage-file
    snapshot-bytes := file.read-contents snap
    blob := find-bytecodes snapshot-bytes bytecodes
    expect blob >= 0

    patched-opcodes := {}
    for i := 0; i < bytecodes.size - 1; i++:
      if coverage[i] != 1: continue  // Not an instruction start.
      op := bytecodes[i]
      if op != LOAD-FIELD and op != STORE-FIELD and op != STORE-FIELD-POP: continue
      if bytecodes[i + 1] != LAST-FIELD: continue
      patched := snapshot-bytes.copy
      patched[blob + i + 1] = PATCHED-FIELD
      out := "$dir/patched.snapshot"
      file.write-contents patched --path=out
      result := run-process [run, "--untrusted", out] --timeout-ms=20_000
      signal := result.exit-signal
      if signal != null:
        expect-not (CRASH-SIGNALS.contains signal)
            --message="crash (signal $signal) from patched opcode $op at bci $i"
      // Unused field accessors (stubs) are never run.
      if result.exit-code == 0 and result.output.contains "value: 41": continue
      if not result.output.contains "INVALID_PROGRAM": print result.output
      // The verifier doesn't prove the receivers of field accesses, so it
      // accepts the program, and the interpreter catches the access.
      expect (result.output.contains "INVALID_PROGRAM")
      expect-not (result.output.contains "VERIFICATION_FAILED")
      expect-not (result.output.contains "value:")
      expect-equals 1 result.exit-code
      patched-opcodes.add (op == LOAD-FIELD ? "load" : "store")

    // Both a load and a store were caught.
    expect-equals 2 patched-opcodes.size
    print "field-access-test OK"
