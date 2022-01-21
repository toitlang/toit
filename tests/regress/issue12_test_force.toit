// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// https://github.com/toitware/toit/issues/12

main:
  a := A
  expect_equals
    "LOOKUP_FAILED"
    catch: a.foo

class A:
  foo:
    this.hash_code

