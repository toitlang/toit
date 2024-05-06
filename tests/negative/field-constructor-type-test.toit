// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// See https://github.com/toitlang/toit/issues/1619.

class A:
  foo/int

  constructor .foo:

class B:
  a/A

  constructor map:
    a = map["foo"]
    print a is A

  foo: return a.foo

main:
  b := B { "foo": "str" }
  print b.foo
