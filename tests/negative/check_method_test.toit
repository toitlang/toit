// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

static foo: unresolved
operator + other: unresolved

foo.bar: unresolved

abstract gee:
  unresolved

class A:
  static constructor: unresolved

  foo.bar: unresolved

abstract class B:
  abstract constructor
  abstract static foo
  abstract bar:
    unresolved

interface C:
  constructor: unresolved

  foo:
    unresolved

  abstract bar

  abstract gee:
    unresolved

monitor D:
  abstract foo

  abstract bar:
    unresolved

main:
