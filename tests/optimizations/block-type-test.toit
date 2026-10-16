// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .utils
import ...tools.snapshot show *
import expect show *

// Block types are checked at `block.call`: the arguments against the
// parameter types and the result against the return type. Positions typed
// `any` (and `none` results) are not checked.
main args:
  snap := run args --entry-path="///untitled" {
    "///untitled": """
    checked x/any [b int -> bool] -> bool:
      return b.call x

    unchecked x/any [b any -> none] -> none:
      b.call x

    main:
      checked 1: it == 1
      unchecked 1: null
    """
  }

  program := snap.decode
  methods := extract-methods program ["checked", "unchecked"]
  AS-CHECKS ::= {
    "AS_CLASS",
    "AS_CLASS_WIDE",
    "AS_INTERFACE",
    "AS_INTERFACE_WIDE",
  }

  count := 0
  methods["checked"].do-bytecodes: | bytecode bci |
    if AS-CHECKS.contains bytecode.name: count++
  // One for the `int` argument, one for the `bool` result.
  expect-equals 2 count

  methods["unchecked"].do-bytecodes: | bytecode bci |
    if AS-CHECKS.contains bytecode.name: throw "Unexpected as check"
