// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Compiled against a copy of the SDK's library whose StringSlice_ does not
// check that its boundaries are character boundaries (run-cut-slice.cmake),
// and run as an untrusted container, like cut-slice-main.toit: the
// concatenations copy cut bytes into strings that are not valid UTF-8.
// The primitives and the message encoder must cope with them
// (docs/sandbox-policy.md, "Threats tested"; until format 1 was refused for
// untrusted programs, invalid-utf-8-literal-test.toit made such strings
// with patched literals of a format-1 program):
// - string-to-utf-16 must not read past a string whose last byte announces
//   more bytes,
// - the object encoder must not walk before a string of continuation bytes
//   (reached through encode-error; encode-object is denied for untrusted
//   programs),
// - such strings can't be sent to another process (the receivers rely on
//   valid strings), in particular not to the system process.

to-utf-16 s:
  #primitive.core.string-to-utf-16

encode-object o:
  #primitive.core.encode-object

encode-error type message:
  #primitive.core.encode-error

process-send pid type message:
  #primitive.core.process-send

main:
  euro := "€"  // E2 82 AC.
  // Seven bytes; the last one is the lead byte of a three-byte sequence.
  truncated := (StringSlice_ ("aaaaaa€" as String_) 0 7) + ""
  // 300 continuation bytes.
  pair := StringSlice_ (euro as String_) 1 3
  continuation := ""
  150.repeat: continuation += pair
  utf-16 := to-utf-16 truncated
  last := utf-16[utf-16.size - 2] | utf-16[utf-16.size - 1] << 8
  print-safe "utf-16 units: $(utf-16.size / 2) last: $(last.stringify 16)"
  encoded := encode-error continuation continuation
  print-safe "encoded: $encoded.size"
  print-safe "encode-object: $(catch: encode-object continuation)"
  exception := catch: process-send -1 100 truncated
  print-safe "send to system: $exception"
  exception = catch: process-send -1 100 [1, [continuation]]
  print-safe "send nested: $exception"
  print-safe "done"

// Printing goes through the system process: only ASCII.
print-safe message/string:
  print message
