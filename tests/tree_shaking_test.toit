// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

class A:
  foo:

class B:

global := 0

side:
  global++

class ClassFirst:
  member1:
    return "good"

  // We discover `method_later` only through the class, which means that the
  // selector (`o.member`) is only discovered when the class already exists.
  through_class o:
    return method_later o

method_later o:
  return o.member1

method_first:
  o := ClassLater
  return o.member2

class ClassLater:
  member2:
    return "good2"

main:
  expect_equals false (A is B)  // Works even if `B` is tree-shaken.
  expect_equals false (side is B)  // Works even if `B` is tree-shaken.
  expect_equals 1 global

  o := ClassFirst
  expect_equals "good" (o.through_class o)

  expect_equals "good2" method_first
