// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .utils
import ...tools.snapshot show *
import expect show *

main args:
  snap := run args --entry-path="///untitled" {
    "///untitled": """
    interface I1:
    interface I2:
    interface I3 extends I1 implements I2:

    mixin M1:
    mixin M2 extends M1:
    mixin M3:
    mixin M4 extends M3 with M2:

    class A implements I3:
    class B extends A with M4:

    global/int := 499

    foo:
      b := B
      b as I1
      b as I2
      b as I3
      b as M1
      b as M2
      b as M3
      b as M4
      global = 42

    main:
      foo
    """
  }

  program := snap.decode
  methods := extract-methods program ["foo"]
  method := methods["foo"]
  UNEXPECTED_TYPE_CHECKS ::= {
    "AS_CLASS",
    "AS_CLASS_WIDE",
    "AS_INTERFACE",
    "AS_INTERFACE_WIDE",
    "IS_CLASS",
    "IS_CLASS_WIDE",
    "IS_INTERFACE",
    "IS_INTERFACE_WIDE",
  }
  UNEXPECTED-TYPE-CHECKS.do: | name |
    expect (BYTE-CODES.any: it.name == name)
  INVOKE-STATIC-NAME ::= "INVOKE_STATIC"
  expect (BYTE-CODES.any: it.name == INVOKE-STATIC-NAME)

  method.do-bytecodes: | bytecode bci |
    if UNEXPECTED-TYPE-CHECKS.contains bytecode.name:
      throw "Unexpected as check"
    if bytecode.name == "INVOKE_STATIC":
      target := target-of-invoke-static program method bci
      expect_equals "constructor" target.name
