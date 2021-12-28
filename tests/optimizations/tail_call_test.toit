// Copyright (C) 2020 Toitware ApS. All rights reserved.

import .utils
import ...tools.snapshot show *
import expect show *

main args:
  snap := run args --entry_path="///untitled" {
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
  methods := extract_methods program ["A.foo"]
  foo_methods := methods["A.foo"]
  expect_equals 2 foo_methods.size
  foo1 /ToitMethod := foo_methods[0]
  foo2 /ToitMethod := foo_methods[1]
  tail_calling /ToitMethod := ?
  if foo1.arity == 1:
    // Just the `this` parameter.
    tail_calling = foo1
  else:
    tail_calling = foo2
  found_tail_call := false
  tail_calling.do_bytecodes:
    expect (not found_tail_call)
    expect it.name != "RETURN"
    if it.name == "INVOKE_STATIC_TAIL":
      found_tail_call = true
  expect found_tail_call
