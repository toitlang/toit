// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// Overrides are only checked against their own return types. The types
// of locals inferred from virtual calls must thus not be used to remove
// runtime checks or to devirtualize calls.

class B:
  m -> int: return 1
  n -> int: return 1
  o -> int: return 1
  opt x=0 -> int: return 1
  blk [b] -> int: return 1
  box -> Box: return Box

class S extends B:
  m -> string: return "str"
  n: return "untyped"
  o -> int?: return null
  opt x=0 -> string: return "str"
  blk [b] -> string: return "str"
  box -> Box: return Box

interface I:
  m -> int

class C implements I:
  m -> string: return "str"

mixin Mix:
  m -> string: return "mixin"

class WithMixin extends B with Mix:

class Box:
  value -> int: return 1

class NotBox:
  value -> string: return "not-box"

class T extends B:
  box -> NotBox: return NotBox

class Foo:
  foo -> string: return "Foo"

class Bar:
  foo -> string: return "Bar"

class FooHolder:
  get -> Foo: return Foo

class BarHolder extends FooHolder:
  get: return Bar

class Compatible:
  m -> num: return 1.5

class CompatibleSub extends Compatible:
  m -> float: return 2.5

make-b -> B: return S

// Inferred as 'int', but holds a string.
untyped-global := make-b.m

main:
  b/B := S
  x := b.m
  expect-throw "AS_CHECK_FAILED":
    y/int := x

  untyped := b.n
  expect-throw "AS_CHECK_FAILED":
    y/int := untyped

  nullable := b.o
  expect-throw "AS_CHECK_FAILED":
    y/int := nullable

  i/I := C
  from-interface := i.m
  expect-throw "AS_CHECK_FAILED":
    y/int := from-interface

  with-mixin/B := WithMixin
  from-mixin := with-mixin.m
  expect-throw "AS_CHECK_FAILED":
    y/int := from-mixin

  // The receiver's type isn't guaranteed either, so neither is the result.
  t/B := T
  not-box := t.box
  value := not-box.value
  expect-throw "AS_CHECK_FAILED":
    y/int := value

  // Arithmetic on untrusted operands: 'int + int' is inferred as 'int'.
  sum := x + x
  expect-throw "AS_CHECK_FAILED":
    y/int := sum

  // Globals without explicit type aren't trusted.
  from-global := untyped-global
  expect-throw "AS_CHECK_FAILED":
    y/int := from-global

  // A trusted inferred type only holds while the local isn't reassigned.
  reassigned := 1
  reassigned = b.m
  copy := reassigned
  expect-throw "AS_CHECK_FAILED":
    y/int := copy

  captured := 1
  lambda := ::
    from-captured := captured
    expect-throw "AS_CHECK_FAILED":
      y/int := from-captured
  captured = b.m
  lambda.call

  for j := 1; true; j = b.m:
    loop-var := j
    if loop-var is string:
      expect-throw "AS_CHECK_FAILED":
        y/int := loop-var
      break

  // Overrides with optional or block parameters are found as well.
  opt := b.opt
  expect-throw "AS_CHECK_FAILED":
    y/int := opt
  blk := b.blk: null
  expect-throw "AS_CHECK_FAILED":
    y/int := blk

  // Don't devirtualize calls on locals with untrusted types.
  holder/FooHolder := BarHolder
  foo := holder.get
  expect-equals "Bar" foo.foo

  // Compatible overrides keep working.
  compatible/Compatible := CompatibleSub
  n := compatible.m
  expect-equals 2.5 n
