// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Exercises TOIT_FORMAT_FLAT_TEST mode, where any expression the flat
// emitter can handle is rewritten to its canonical flat form with paren
// insertion. The AST-equivalence check in the formatter is the real
// validator — if paren rules were wrong we'd crash on write. This
// additionally pins a few expected text outputs so regressions surface
// as obvious string diffs.

import expect show *
import host.file
import host.os

import ..toit.utils

class Case:
  label/string
  input/string
  expected/string
  constructor --.label --.input --.expected:

CASES ::= [
  Case
      --label="same-precedence chain gets parenthesized on the left"
      --input="""
        main:
          a := 1
          b := 2
          c := 3
          a + b + c
        """
      --expected="""
        main:
          a := 1
          b := 2
          c := 3
          (a + b) + c
        """,

  Case
      --label="different precedences keep natural shape"
      --input="""
        main:
          a := 1
          b := 2
          c := 3
          a + b * c
          a * b + c
        """
      --expected="""
        main:
          a := 1
          b := 2
          c := 3
          a + b * c
          a * b + c
        """,

  Case
      --label="unary and dot are emitted without extra whitespace"
      --input="""
        main:
          foo := 0
          a := 1
          -a
          not a
          foo.bar
        """
      --expected="""
        main:
          foo := 0
          a := 1
          -a
          not a
          foo.bar
        """,

  Case
      --label="collection literals in flat form"
      --input="""
        main:
          [1, 2, 3]
          [1 + 2, 3 * 4]
          {1, 2, 3}
          {"a": 1, "b": 2}
          #[0x01, 0x02, 0xff]
          []
          {:}
        """
      --expected="""
        main:
          [1, 2, 3]
          [1 + 2, 3 * 4]
          {1, 2, 3}
          {"a": 1, "b": 2}
          #[0x01, 0x02, 0xff]
          []
          {:}
        """,

  Case
      --label="index and slice flat forms"
      --input="""
        main:
          arr := [1, 2, 3, 4, 5]
          arr[0]
          arr[1, 2]
          arr[1..3]
          arr[..2]
          arr[1..]
          arr[..]
        """
      --expected="""
        main:
          arr := [1, 2, 3, 4, 5]
          arr[0]
          arr[1, 2]
          arr[1..3]
          arr[..2]
          arr[1..]
          arr[..]
        """,

  Case
      --label="calls with various args keep their shapes"
      --input="""
        main:
          foo
          foo 1 2
          foo "hello" 42
          foo (1 + 2)
          foo.bar 1
        """
      --expected="""
        main:
          foo
          foo 1 2
          foo "hello" 42
          foo (1 + 2)
          foo.bar 1
        """,

  Case
      --label="named arguments round-trip flat"
      --input="""
        main:
          foo --flag
          foo --no-flag
          foo --key=42
          a := 1
          b := 2
          foo --key=(a + b)
        """
      --expected="""
        main:
          foo --flag
          foo --no-flag
          foo --key=42
          a := 1
          b := 2
          foo --key=(a + b)
        """,

  Case
      --label="unary over parenthesized binary keeps the parens"
      --input="""
        main:
          a := 1
          b := 2
          -(a + b)
        """
      --expected="""
        main:
          a := 1
          b := 2
          -(a + b)
        """,
]

main args:
  toit-exe := ToitExecutable args
  // Turn on always-flat mode for every `toit format` subprocess invoked
  // from this test — host.pipe inherits the parent's env.
  os.env["TOIT_FORMAT_FLAT_TEST"] = "1"

  with-tmp-dir: | tmp-dir/string |
    CASES.size.repeat: | i/int |
      c := CASES[i]
      tmp-path := "$tmp-dir/flat-$(i).toit"
      file.write-contents --path=tmp-path c.input
      toit-exe.backticks ["format", tmp-path]
      got := (file.read-contents tmp-path).to-string

      if got != c.expected:
        print "UNEXPECTED FLAT OUTPUT ($c.label):"
        print "--- input ---"
        print c.input
        print "--- got ---"
        print got
        print "--- expected ---"
        print c.expected
        expect false --message="flat-mode output mismatch for $c.label"
