// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class B:
  field0 /any

  field1 := ?
  field2 /any := ?
  field3 /int := ?

  field4 ::= ?
  field5 /any ::= ?
  field6 /int? ::= ?

main:
  b := B
  b.field0 = 111
  b.field4 = 499
  b.field5 = 42
  b.field6 = null

  b.field3 = "str"
  b.field6 = "str"

  unresolved
