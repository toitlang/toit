// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Feeds deliberately mis-indented Toit into the formatter and asserts the
// output matches the canonical form. Also checks idempotence on each case.

import expect show *
import host.file

import ..toit.utils

class Case:
  label/string
  input/string
  expected/string
  constructor --.label --.input --.expected:

CASES ::= [
  Case
      --label="class members over-indented"
      --input="""
        class Foo:
            x ::= 1
            y ::= 2

        main:
          print 1
        """
      --expected="""
        class Foo:
          x ::= 1
          y ::= 2

        main:
          print 1
        """,

  Case
      --label="method body over-indented"
      --input="""
        class Foo:
          bar:
              return 42

        main:
          print 1
        """
      --expected="""
        class Foo:
          bar:
            return 42

        main:
          print 1
        """,

  Case
      --label="class header over-indented at top level"
      --input="""
           class Foo:
          x ::= 1

        main:
          print 1
        """
      --expected="""
        class Foo:
          x ::= 1

        main:
          print 1
        """,

  Case
      --label="if body over-indented"
      --input="""
        main:
          if true:
              print 1
              print 2
        """
      --expected="""
        main:
          if true:
            print 1
            print 2
        """,

  Case
      --label="if-else with both branches over-indented"
      --input="""
        main:
          if true:
              print 1
          else:
              print 2
        """
      --expected="""
        main:
          if true:
            print 1
          else:
            print 2
        """,

  Case
      --label="else-if chain re-indents with its parent if"
      --input="""
        class Foo:
          constructor:
              if true:
                print 1
              else if false:
                print 2
              else:
                print 3
        """
      --expected="""
        class Foo:
          constructor:
            if true:
              print 1
            else if false:
              print 2
            else:
              print 3
        """,

  Case
      --label="while body over-indented"
      --input="""
        main:
          i := 0
          while i < 3:
              print i
              i++
        """
      --expected="""
        main:
          i := 0
          while i < 3:
            print i
            i++
        """,

  Case
      --label="flat call multi-space is canonicalized"
      --input="""
        main:
          print  "hello"
          foo  bar   baz
        """
      --expected="""
        main:
          print "hello"
          foo bar baz
        """,

  Case
      --label="well-formed input is unchanged"
      --input="""
        class Foo:
          x ::= 1
          bar:
            return x

        main:
          print (Foo).bar
        """
      --expected="""
        class Foo:
          x ::= 1
          bar:
            return x

        main:
          print (Foo).bar
        """,
]

main args:
  toit-exe := ToitExecutable args

  with-tmp-dir: | tmp-dir/string |
    CASES.size.repeat: | i/int |
      c := CASES[i]
      tmp-path := "$tmp-dir/case-$(i).toit"
      file.write-contents --path=tmp-path c.input

      toit-exe.backticks ["format", tmp-path]
      once := (file.read-contents tmp-path).to-string

      if once != c.expected:
        print "UNEXPECTED OUTPUT ($c.label):"
        print "--- input ---"
        print c.input
        print "--- got ---"
        print once
        print "--- expected ---"
        print c.expected
        expect false --message="unexpected format output for $c.label"

      toit-exe.backticks ["format", tmp-path]
      twice := (file.read-contents tmp-path).to-string
      if once != twice:
        print "IDEMPOTENCE FAILURE ($c.label):"
        print "--- after one format ---"
        print once
        print "--- after two formats ---"
        print twice
        expect false --message="formatter not idempotent on $c.label"
