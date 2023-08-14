// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

CONST ::= 499
A-B ::= 43

class A:
  CONST ::= 499
  _ ::= 42
  A-B ::= 43
  A-B499 ::= 43
  __ ::= 42

  NON-CONST := 1
  NON-CONST2 := ?

  constructor:
    NON-CONST2 = 2

main:
  a := A
