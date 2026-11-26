// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Since format 3 (verified/spec/format/23-format3-try.md) the verified
// core's programs carry the tag "TBC3". A program with another "TBC" digit
// (an image of an earlier version, TBC1 or TBC2) is refused where a program
// is started and never reaches the format-1 C++ interpreter
// (Program::has_stale_v2_tag): this test patches the tag of a compiled
// snapshot and runs it trusted, untrusted, through the verifier and the
// certifier.

import expect show *
import host.file
import .sandbox-util show *

PROGRAM ::= """
main:
  print "stale program ran"
"""

/** Replaces the unique occurrence of $from in $bytes by $to. */
replace-unique bytes/ByteArray from/ByteArray to/ByteArray -> none:
  found := -1
  for i := 0; i + from.size <= bytes.size; i++:
    if bytes[i..i + from.size] == from:
      if found >= 0: throw "tag not unique"
      found = i
  if found < 0: throw "tag not found"
  bytes.replace found to

main args:
  run := args[0]
  compiler := args[1]
  environment := {"TOIT_BYTECODE_FORMAT": "2"}
  with-tmp-directory: | dir |
    source := "$dir/prog.toit"
    write-file source PROGRAM
    snap := "$dir/prog.snapshot"
    compiled := run-process [compiler, "-w", snap, source] --environment=environment
    expect-equals 0 compiled.exit-code
    base := run-process [run, snap] --timeout-ms=60_000 --environment=environment
    expect (base.output.contains "stale program ran")

    ['1', '2', '9'].do: | digit/int |
      bytes := file.read-contents snap
      replace-unique bytes "TBC3".to-byte-array #['T', 'B', 'C', digit]
      stale := "$dir/stale-$(string.from-rune digit).snapshot"
      file.write-contents bytes --path=stale
      message := "bytecode format TBC$(string.from-rune digit) is not supported by this VM; recompile"
      [[], ["--untrusted"]].do: | flags/List |
        result := run-process [run] + flags + [stale] --timeout-ms=60_000 --environment=environment
        print result.output
        expect-not (result.output.contains "stale program ran")
        expect (result.output.contains message)
        expect-not-equals 0 result.exit-code
      verified := run-process [run, "--verify", stale] --timeout-ms=60_000 --environment=environment
      print verified.output
      expect (verified.output.contains message)
      expect (verified.output.contains "REJECTED")
      expect-equals 1 verified.exit-code
      certified := run-process [run, "--certify", stale] --timeout-ms=60_000 --environment=environment
      print certified.output
      expect (certified.output.contains "is not supported by this VM")
      expect-equals 1 certified.exit-code
