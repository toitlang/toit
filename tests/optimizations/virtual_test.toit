// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .utils
import ...tools.snapshot show *
import expect show *

main args:
  snap := run args --entry_path="///untitled" {
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

    main:
      (A).foo
      (B).foo
      (B).foo2
      A.namedA
      B.namedB
    """
  }

  program := snap.decode
  methods := extract_methods program ["A.foo", "B.foo2", "A", "A.namedA", "B", "B.namedB"]
  expectations := {
    "A.foo": [true, false],
    "A": [true, false],
    "A.namedA": [true, false],
    "B.foo2": [false, true],
    "B": [false, true],
    "B.namedB": [false, true],
  }
  expectations.do: |method_name expectation|
    method := methods[method_name]
    contains_virtual_call := false
    contains_static_call := false
    method.do_bytecodes:
      if it.name == "INVOKE_STATIC":
        contains_static_call = true
      else if it.name.starts_with "INVOKE" and not it.name == "INVOKE_BLOCK":
        contains_virtual_call = true
    expect_equals expectation[0] contains_virtual_call
    expect_equals expectation[1] contains_static_call
