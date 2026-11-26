// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// This test patches string literals of a compiled snapshot so that they
// aren't valid UTF-8 and runs it as an untrusted container.
//
// Untrusted programs are in format 2: the verifier checks the string
// literals at launch (the loader's contract `loaded_ok`, verified/spec
// heap_check.rs), so the patched program is rejected and never runs.
//
// A crafted program can still hold strings that aren't valid UTF-8 at run
// time: a string slice with crafted bounds (crafted bytecode can store its
// final fields) can cut a sequence, and string-add copies it. That the VM
// copes with such strings is tested with cut slices by
// tests/sandbox/cli/invalid-strings-main.toit (this test did it with a
// patched format-1 program while untrusted format 1 could be allowed).

import expect show *
import host.file
import .sandbox-util show *

TRUNCATED-MARKER ::= "TRUNCATED-QZQZQZ"
CONTINUATION-MARKER ::= "C" * 300

PROGRAM ::= """
to-utf-16 s:
  #primitive.core.string-to-utf-16

encode-object o:
  #primitive.core.encode-object

encode-error type message:
  #primitive.core.encode-error

process-send pid type message:
  #primitive.core.process-send

main:
  truncated := "$TRUNCATED-MARKER"
  continuation := "$CONTINUATION-MARKER"
  utf-16 := to-utf-16 truncated
  last := utf-16[utf-16.size - 2] | utf-16[utf-16.size - 1] << 8
  print-safe "utf-16 units: \$(utf-16.size / 2) last: \$(last.stringify 16)"
  encoded := encode-error continuation continuation
  print-safe "encoded: \$encoded.size"
  print-safe "encode-object: \$(catch: encode-object continuation)"
  exception := catch: process-send -1 100 truncated
  print-safe "send to system: \$exception"
  exception = catch: process-send -1 100 [1, [continuation]]
  print-safe "send nested: \$exception"
  print-safe "done"

// Printing goes through the system process: only ASCII.
print-safe message/string:
  print message
"""

/** Replaces the bytes of $marker in $bytes with $replacement. */
patch bytes/ByteArray marker/string replacement/ByteArray -> none:
  needle := marker.to-byte-array
  for i := 0; i + needle.size <= bytes.size; i++:
    if bytes[i..i + needle.size] == needle:
      bytes.replace i replacement
      return
  throw "marker not found: $marker"

/**
Compiles $PROGRAM in the given bytecode $format, checks that it runs as an
  untrusted container, and returns the path of a copy of its snapshot with
  the patched literals.
*/
compile-patched run/string compiler/string dir/string --format/int --environment/Map -> string:
  source := "$dir/prog.toit"
  write-file source PROGRAM
  snap := "$dir/prog-$(format).snapshot"
  compiled := run-process [compiler, "-w", snap, source] --environment={"TOIT_BYTECODE_FORMAT": "$format"}
  if compiled.exit-code != 0: throw "compilation failed: $compiled.output"

  base := run-process [run, "--untrusted", snap] --timeout-ms=60_000 --environment=environment
  print base.output
  expect-equals 0 base.exit-code
  expect (base.output.contains "send to system: null")

  bytes := file.read-contents snap
  // The last byte of the truncated string announces seven more bytes.
  truncated := TRUNCATED-MARKER.to-byte-array
  truncated[truncated.size - 1] = 0xff
  patch bytes TRUNCATED-MARKER truncated
  // The continuation string is 300 continuation bytes.
  patch bytes CONTINUATION-MARKER (ByteArray CONTINUATION-MARKER.size: 0x80)
  patched := "$dir/patched-$(format).snapshot"
  file.write-contents bytes --path=patched
  return patched

main args:
  run := args[0]
  compiler := args[1]
  with-tmp-directory: | dir |
    // Format 2: the verifier rejects the literals at launch.
    environment := {"TOIT_BYTECODE_FORMAT": "2"}
    patched := compile-patched run compiler dir --format=2 --environment=environment
    rejected := run-process [run, "--untrusted", patched] --timeout-ms=60_000 --environment=environment
    print rejected.output
    expect-equals 1 rejected.exit-code
    expect (rejected.output.contains "a string literal isn't valid UTF-8")
    expect (rejected.output.contains "VERIFICATION_FAILED")
    expect-not (rejected.output.contains "utf-16 units")
