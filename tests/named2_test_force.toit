// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

glob := []

class A:
  constructor:
    glob.add "A"

class B extends A:
  x := null

  constructor:
    glob.add "B"
    this.x --val=499
    glob.add "B2"

class C extends B:
  x --val:
    glob.add "x setter in C"


main:
  c := C
  expect_equals 4 glob.size
  expected := ["B", "A", "x setter in C", "B2"]
  for i := 0; i < glob.size; i++:
    expect_equals expected[i] glob[i]
