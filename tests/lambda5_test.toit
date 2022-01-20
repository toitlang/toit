// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test for issue 1270.
// We would see that a parameter was of index 0, and assume that it
//   was 'this'. However, that's not true for lambda arguments.
import expect show *

run f: return f.call

class A:
  foo: return "A_foo"

  bar:
    // By looking at the bytecodes, we should see static calls to "A.foo" here.
    expect_equals "A_foo" (run:: foo)
    expect_equals "A_foo" (run:: this.foo)
    b := B
    // Despite being argument 0 to the lambda, we must not do a static call to "A.foo".
    expect_equals "B_foo" (run:: b.foo)

class B:
  foo: return "B_foo"

main:
  (A).bar
