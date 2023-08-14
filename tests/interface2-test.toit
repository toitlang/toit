// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import .inter as pre

interface A:
  a-method x
  static static-a: return "static a"

interface B A implements pre.I:
  b-method x y
  // Implemented methods need to be redeclared.
  i-method

class C implements B:
  as-a -> A: return this
  as-b -> B: return this
  as-i -> pre.I: return this

  a-method x/pre.I: return "a_method"
  b-method x/A y/B: return "b_method"
  i-method: return "i_method"

interface D:

class E:

main:
  c := C
  expect-equals "a_method" (c.a-method c)
  expect-equals "b_method" (c.b-method c c)
  expect-equals "i_method" c.i-method

  expect-equals "static a" A.static-a
  expect-equals "static i" pre.I.static-i

  expect c is A
  expect c is B
  expect c is pre.I
  expect c is C
  expect (not c is D)
  expect (not c is E)
