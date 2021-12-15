// Copyright (C) 2020 Toitware ApS. All rights reserved.

import expect show *

expect_throws name [code]:
  expect_equals
    name
    catch code

class A:
  field /B := ?

  constructor .field:

  foo:
    // The class `B` is tree-shaken, and the accesses to the fields can't
    //   be optimized.
    print field.bar
    field.bar = 42

class B:
  bar := 499

confuse x -> any: return x

as_B x -> B: return x

main:
  something /any := null
  if confuse false:
    a := A something
    a.foo

  expect_throws "AS_CHECK_FAILED": (something as B).bar
  expect_throws "AS_CHECK_FAILED": (something as B).bar = 42
  expect_throws "AS_CHECK_FAILED": (as_B something).bar
  expect_throws "AS_CHECK_FAILED": (as_B something).bar = 42
