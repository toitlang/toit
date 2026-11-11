// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// A crafted program can hold strings that aren't valid UTF-8: the string
// literals of a snapshot are not checked (and a string slice with crafted
// bounds can cut a sequence). This test patches string literals of a
// compiled snapshot and runs it as an untrusted container:
// - string-to-utf-16 must not read past a string whose last byte announces
//   more bytes (0xff: seven),
// - the object encoder must not walk before a string of continuation bytes
//   (reached through encode-error; encode-object is denied for untrusted
//   programs),
// - such strings can't be sent to another process (the receivers rely on
//   valid strings), in particular not to the system process.

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

main args:
  run := args[0]
  compiler := args[1]
  with-tmp-directory: | dir |
    snap := "$dir/prog.snapshot"
    write-file "$dir/prog.toit" PROGRAM
    compile-snapshot compiler "$dir/prog.toit" snap

    base := run-process [run, "--untrusted", snap] --timeout-ms=60_000
    expect-equals 0 base.exit-code
    expect (base.output.contains "send to system: null")

    bytes := file.read-contents snap
    // The last byte of the truncated string announces seven more bytes.
    truncated := TRUNCATED-MARKER.to-byte-array
    truncated[truncated.size - 1] = 0xff
    patch bytes TRUNCATED-MARKER truncated
    // The continuation string is 300 continuation bytes.
    patch bytes CONTINUATION-MARKER (ByteArray CONTINUATION-MARKER.size: 0x80)
    patched := "$dir/patched.snapshot"
    file.write-contents bytes --path=patched

    result := run-process [run, "--untrusted", patched] --timeout-ms=60_000
    print result.output
    expect-equals 0 result.exit-code
    // 16 units; the last byte is the replacement character, not whatever
    // followed the string in memory.
    expect (result.output.contains "utf-16 units: 16 last: fffd")
    expect (result.output.contains "encoded: ")
    expect (result.output.contains "encode-object: PERMISSION_DENIED")
    expect (result.output.contains "send to system: WRONG_OBJECT_TYPE")
    expect (result.output.contains "send nested: WRONG_OBJECT_TYPE")
    expect (result.output.contains "done")
