// Copyright (C) 2019 Toitware ApS. All rights reserved.

import expect show *

import .inter as pre

interface A:
  a_method x
  static static_a: return "static a"

interface B:
  b_method x y

class C implements A B pre.I:
  as_a -> A: return this
  as_b -> B: return this
  as_i -> pre.I: return this

  a_method x/pre.I: return "a_method"
  b_method x/A y/B: return "b_method"
  i_method: return "i_method"

main:
  c := C
  expect_equals "a_method" (c.a_method c)
  expect_equals "b_method" (c.b_method c c)
  expect_equals "i_method" c.i_method

  expect_equals "static a" A.static_a
  expect_equals "static i" pre.I.static_i
