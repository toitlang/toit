// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Tests that the interpreter checks the field accesses of untrusted programs
// at run time, in every build. It patches the field index of the LOAD_FIELD
// and STORE_FIELD instructions of a method to a value past the end of the
// instance, runs the patched snapshot as an untrusted program, and checks
// that the access throws INVALID_PROGRAM instead of reading or writing past
// the end of the object.

import expect show *
import host.file
import .sandbox-util show *
import ...tools.snapshot show SnapshotBundle ToitMethod

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

  with-tmp-directory: | dir |
    snap := "$dir/prog.snapshot"
    write-file "$dir/prog.toit" program-source
    compile-snapshot compiler "$dir/prog.toit" snap

    // The unmodified program runs as an untrusted program.
    base := run-process [run, "--untrusted", snap] --timeout-ms=20_000
    if base.exit-code != 0: print base.output
    expect-equals 0 base.exit-code
    expect (base.output.contains "value: 41")

    program := (SnapshotBundle.from-file snap).decode
    bytecodes := program.all-bytecodes
    snapshot-bytes := file.read-contents snap
    blob := find-bytecodes snapshot-bytes bytecodes
    expect blob >= 0

    patched-opcodes := {}
    program.methods.do: | method/ToitMethod |
      method.do-bytecodes: | bytecode index |
        bci := method.absolute-entry-bci + index
        name := bytecode.name
        if (name == "LOAD_FIELD" or name == "STORE_FIELD" or name == "STORE_FIELD_POP")
            and bytecodes[bci + 1] == LAST-FIELD:
          patched := snapshot-bytes.copy
          patched[blob + bci + 1] = PATCHED-FIELD
          out := "$dir/patched.snapshot"
          file.write-contents patched --path=out
          result := run-process [run, "--untrusted", out] --timeout-ms=20_000
          signal := result.exit-signal
          if signal != null:
            expect-not (CRASH-SIGNALS.contains signal)
                --message="crash (signal $signal) from patched $name at bci $bci"
          // Unused field accessors (stubs) are never run.
          if not (result.exit-code == 0 and result.output.contains "value: 41"):
            if not result.output.contains "INVALID_PROGRAM": print result.output
            expect (result.output.contains "INVALID_PROGRAM")
            expect-not (result.output.contains "value:")
            expect-equals 1 result.exit-code
            patched-opcodes.add (name == "LOAD_FIELD" ? "load" : "store")

    // Both a load and a store were caught.
    expect-equals 2 patched-opcodes.size
    print "field-access-test OK"
