// Copyright (C) 2020 Toitware ApS. All rights reserved.
// TEST_FLAGS: --force

/// Test that optimizations don't trigger when there was an
///   an error during compilation.
/// Specifically we can't trust types anymore.

class A:
  field/string

  foo:
    return field.copy 2

main:
  a := A
  a.foo
