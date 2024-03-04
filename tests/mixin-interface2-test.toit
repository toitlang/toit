// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

interface I1:
  foo

mixin FooMixin:
  foo: return 499

class A extends Object with FooMixin implements I1:

main:
  a := A
  expect-equals 499 a.foo
