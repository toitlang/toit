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
      foo optional=499:
        return optional

    main:
      (A).foo 1
      (A).foo
    """
  }

  program := snap.decode
  methods := extract-methods program ["A.foo"]
  foo-methods := methods["A.foo"]
  expect-equals 2 foo-methods.size
  foo1 /ToitMethod := foo-methods[0]
  foo2 /ToitMethod := foo-methods[1]
  tail-calling /ToitMethod := ?
  if foo1.arity == 1:
    // Just the `this` parameter.
    tail-calling = foo1
  else:
    tail-calling = foo2
  found-tail-call := false
  tail-calling.do-bytecodes:
    expect (not found-tail-call)
    expect it.name != "RETURN"
    if it.name == "INVOKE_STATIC_TAIL":
      found-tail-call = true
  expect found-tail-call
