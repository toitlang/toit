// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  test-derived Derived
  test-derived ReallyDerived

  r := ReallyDerived
  expect r.swoop == 99

test-derived derived:
  expect derived.foo == 17
  expect derived.bar == 19
  expect (derived.baz 3) == 3 + 2 + 1
  expect (derived.baz 4) == 4 + 2 + 1
  expect derived.biz == 42 + 11
  expect (derived.bun 13) == 87 - 13
  expect derived.x == 42
  expect derived.y == 87
  expect-equals
    2
    derived.exec 1: it
  expect-equals
    3
    derived.exec 2: it

class Base:
  x := 42

  foo:
    return 17
  baz n:
    return n + 1
  biz:
    return 42
  bun:
    return 87

  exec n [block]:
    return block.call n

class Derived extends Base:
  y := 87

  bar:
    return 19
  baz n:
    return super n + 2
  biz:
    return super + 11
  bun n:
    return super - n

  exec n [block]:
    return super n: block.call it + 1

  swoop:
    return (this as any).bunker  // Can't do implicit calls that aren't resolved. Prefix with `this.`.

class ReallyDerived extends Derived:
  bunker := 99
