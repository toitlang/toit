// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

class A:
class B extends A:
  foo: return 499

class C:
  field / A := A

// Should not have a warning, as the assignment uses the RHS of the assignment.
bar c/C -> B: return c.field = B

main:
  c := C
  // Should not have any warning, as the assignment uses the RHS of the assignment.
  expect_equals 499 (bar c).foo
