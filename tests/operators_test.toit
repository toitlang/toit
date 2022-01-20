// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

class A:
  operator == other: return "== $other"
  operator < other: return "< $other"
  operator <= other: return "<= $other"
  operator >= other: return ">= $other"
  operator > other: return "> $other"
  operator + other: return "+ $other"
  operator - other: return "- $other"
  operator * other: return "* $other"
  operator / other: return "/ $other"
  operator % other: return "% $other"
  operator ^ other: return "^ $other"
  operator & other: return "& $other"
  operator | other: return "| $other"
  operator >> other: return ">> $other"
  operator >>> other: return ">>> $other"
  operator << other: return "<< $other"

  operator -: return "-"
  operator ~: return "~"

main:
  expect_equals "== 499" A == 499
  expect_equals "< 499" A < 499
  expect_equals "<= 499" A <= 499
  expect_equals ">= 499" A >= 499
  expect_equals "> 499" A > 499
  expect_equals "+ 499" A + 499
  expect_equals "- 499" A - 499
  expect_equals "* 499" A * 499
  expect_equals "/ 499" A / 499
  expect_equals "% 499" A % 499
  expect_equals "^ 499" A ^ 499
  expect_equals "& 499" A & 499
  expect_equals "| 499" A | 499
  expect_equals ">> 499" A >> 499
  expect_equals ">>> 499" A >>> 499
  expect_equals "<< 499" A << 499

  expect_equals "~" ~A
  expect_equals "-" -A
