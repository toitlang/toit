// Copyright (C) 2018 Toitware ApS.
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
  through-class o:
    return method-later o

method-later o:
  return o.member1

method-first:
  o := ClassLater
  return o.member2

class ClassLater:
  member2:
    return "good2"

main:
  expect-equals false (A is B)  // Works even if `B` is tree-shaken.
  expect-equals false (side is B)  // Works even if `B` is tree-shaken.
  expect-equals 1 global

  o := ClassFirst
  expect-equals "good" (o.through-class o)

  expect-equals "good2" method-first
