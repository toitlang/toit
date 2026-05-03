// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
  constructor:
  constructor.named:
  foo: return 1
  bar x: return x

class B extends A:
  foo:
    // Should warn: super.foo is (super).foo.
    return super.foo + 1

  bar x:
    // Should warn: super.bar is (super).bar.
    return super.bar x

  gee:
    // Should not warn: plain super is fine.
    return super

class C extends A:
  constructor.named:
    // Should not warn: constructor super call.
    super

  constructor.with-dot:
    // Should not warn: super.named is a named constructor call.
    super.named

class D extends A:
  foo:
    // Should not warn: uses parentheses.
    return (super).foo + 1

main:
