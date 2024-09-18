// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .utils
import ...tools.snapshot show *
import expect show *

main args:
  snap := run args --entry-path="///untitled" {
    "///untitled": """
    class A:
      constructor:
        bar
      constructor.namedA:
        bar

      foo:
        bar
      bar:
        print "do something meaningful"

    class B extends A:
      constructor:
        bar
      constructor.namedB:
        bar

      foo2:
        bar
      bar:
        print "do something meaningful2"

    literal-virtual:
      "literal-type".to-ascii-upper

    main:
      (A).foo
      (B).foo
      (B).foo2
      A.namedA
      B.namedB
      literal-virtual
    """
  }

  program := snap.decode
  methods := extract-methods program ["A.foo", "B.foo2", "A", "A.namedA", "B", "B.namedB", "literal-virtual"]
  expectations := {
    "A.foo": [true, false],
    "A": [true, false],
    "A.namedA": [true, false],
    "B.foo2": [false, true],
    "B": [false, true],
    "B.namedB": [false, true],
    "literal-virtual": [false, true],
  }
  expectations.do: |method-name expectation|
    method := methods[method-name]
    contains-virtual-call := false
    contains-static-call := false
    method.do-bytecodes:
      if it.name == "INVOKE_STATIC":
        contains-static-call = true
      else if it.name.starts-with "INVOKE" and not it.name == "INVOKE_BLOCK":
        contains-virtual-call = true
    expect-equals expectation[0] contains-virtual-call
    expect-equals expectation[1] contains-static-call
