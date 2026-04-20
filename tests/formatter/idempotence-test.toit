// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.file

import ..toit.utils

SNIPPETS ::= [
  """
  main: print "hi"
  """,

  """
  main:
    print "hello"
    print "world"
  """,

  """
  class Foo:
    bar: return 42

  main:
    foo := Foo
    print foo.bar
  """,

  """
  import host.file

  main args/List:
    if args.size > 0:
      print args[0]
    else:
      print "no args"
  """,

  """
  fib n:
    if n < 2: return n
    return (fib n - 1) + (fib n - 2)

  main:
    print (fib 10)
  """,
]

check-format toit-exe/ToitExecutable src-path/string label/string:
  original := (file.read-contents src-path).to-string
  toit-exe.backticks ["format", src-path]
  once := (file.read-contents src-path).to-string
  toit-exe.backticks ["format", src-path]
  twice := (file.read-contents src-path).to-string

  // Idempotence: format(format(S)) == format(S).  Permanent invariant.
  if once != twice:
    print "IDEMPOTENCE FAILURE ($label):"
    print "--- original ---"
    print original
    print "--- after first format ---"
    print once
    print "--- after second format ---"
    print twice
    expect false --message="formatter not idempotent on $label"

main args:
  toit-exe := ToitExecutable args

  with-tmp-dir: | tmp-dir/string |
    SNIPPETS.size.repeat: | i/int |
      src-path := "$tmp-dir/snippet-$(i).toit"
      file.write-contents --path=src-path SNIPPETS[i]
      check-format toit-exe src-path "snippet-$(i)"
