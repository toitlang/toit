// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

CONST ::= 499
A_B ::= 43

class A:
  CONST ::= 499
  _ ::= 42
  A_B ::= 43
  __ ::= 42

  NON_CONST := 1
  NON_CONST2 := ?

  constructor:
    NON_CONST2 = 2

main:
  a := A
