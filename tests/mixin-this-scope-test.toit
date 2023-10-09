// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

mixin MixA:
  a-method: return 41

mixin MixB extends MixA:
  b-method: return 42

abstract mixin MixC extends MixB:
  abstract c-method -> int

class ClassA extends Object with MixC:
  c_method: return 43

  check-this-calls:
    expect-equals 41 a-method
    expect-equals 42 b-method
    expect-equals 43 c-method

abstract mixin MixForMixin:
  abstract e-method -> int

mixin MixD extends MixA with MixForMixin:
  e_method: return 499

class ClassB extends Object with MixD:
  c_method: return 42

  check-this-calls:
    expect-equals 41 a-method
    expect-equals 42 c-method
    expect-equals 499 e-method

main:
