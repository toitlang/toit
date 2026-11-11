// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// A crafted program can hold strings that aren't valid UTF-8: the string
// literals of a snapshot are not checked (and a string slice with crafted
// bounds can cut a sequence). This test patches string literals of a
// compiled snapshot and runs it as an untrusted container: such strings
// can't be sent to another process (the receivers rely on valid strings),
// in particular not to the system process.

import expect show *
import host.file
import .sandbox-util show *

TRUNCATED-MARKER ::= "TRUNCATED-QZQZQZ"
CONTINUATION-MARKER ::= "C" * 300

PROGRAM ::= """
process-send pid type message:
  #primitive.core.process-send

main:
  truncated := "$TRUNCATED-MARKER"
  continuation := "$CONTINUATION-MARKER"
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
    expect (base.output.contains "send nested: null")

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
    expect (result.output.contains "send to system: WRONG_OBJECT_TYPE")
    expect (result.output.contains "send nested: WRONG_OBJECT_TYPE")
    expect (result.output.contains "done")
