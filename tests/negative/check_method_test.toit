// Copyright (C) 2019 Toitware ApS. All rights reserved.

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
