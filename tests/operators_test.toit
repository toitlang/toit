// Copyright (C) 2019 Toitware ApS. All rights reserved.

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
