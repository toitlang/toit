// Copyright (C) 2018 Toitware ApS. All rights reserved.

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

