// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
class B extends A:
  foo: return 499

class C:
  field / A := A

// Should not have any warning as the assignment uses the RHS of the assignment.
test1 c /C -> B: return c.field = B
test2 c /C -> B:
  dynamic := confuse B
  return c.field = dynamic

test3 c /C -> string:
  // No warning for the return type, but a warning for the field assignment.
  return c.field = "str"

confuse x: return x

main:
  c := C
  test1 c
  test2 c
  test3 c
  unresolved
