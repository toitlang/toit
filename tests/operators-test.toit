// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

class A:
  last-operator/string? := null

  operator == other:
    last-operator = "== $other"
    return true
  operator < other:
    last-operator = "< $other"
    return true
  operator <= other:
    last-operator = "<= $other"
    return true
  operator >= other:
    last-operator = ">= $other"
    return true
  operator > other:
    last-operator = "> $other"
    return true
  operator + other:
    last-operator = "+ $other"
    return true
  operator - other:
    last-operator = "- $other"
    return true
  operator * other:
    last-operator = "* $other"
    return true
  operator / other:
    last-operator = "/ $other"
    return true
  operator % other:
    last-operator = "% $other"
    return true
  operator ^ other:
    last-operator = "^ $other"
    return true
  operator & other:
    last-operator = "& $other"
    return true
  operator | other:
    last-operator = "| $other"
    return true
  operator >> other:
    last-operator = ">> $other"
    return true
  operator >>> other:
    last-operator = ">>> $other"
    return true
  operator << other:
    last-operator = "<< $other"
    return true

  operator -:
    last-operator = "-"
    return true
  operator ~:
    last-operator = "~"
    return true

main:
  a := A
  a == 499
  expect-equals "== 499" a.last-operator
  a < 499
  expect-equals "< 499" a.last-operator
  a <= 499
  expect-equals "<= 499" a.last-operator
  a >= 499
  expect-equals ">= 499" a.last-operator
  a > 499
  expect-equals "> 499" a.last-operator
  a + 499
  expect-equals "+ 499" a.last-operator
  a - 499
  expect-equals "- 499" a.last-operator
  a * 499
  expect-equals "* 499" a.last-operator
  a / 499
  expect-equals "/ 499" a.last-operator
  a % 499
  expect-equals "% 499" a.last-operator
  a ^ 499
  expect-equals "^ 499" a.last-operator
  a & 499
  expect-equals "& 499" a.last-operator
  a | 499
  expect-equals "| 499" a.last-operator
  a >> 499
  expect-equals ">> 499" a.last-operator
  a >>> 499
  expect-equals ">>> 499" a.last-operator
  a << 499
  expect-equals "<< 499" a.last-operator

  ~a
  expect-equals "~" a.last-operator
  -a
  expect-equals "-" a.last-operator
