// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import .confuse

expect-throws name [code]:
  expect-equals
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

as-B x -> B: return x

main:
  something /any := null
  if confuse false:
    a := A something
    a.foo

  expect-throws "AS_CHECK_FAILED": (something as B).bar
  expect-throws "AS_CHECK_FAILED": (something as B).bar = 42
  expect-throws "AS_CHECK_FAILED": (as-B something).bar
  expect-throws "AS_CHECK_FAILED": (as-B something).bar = 42
