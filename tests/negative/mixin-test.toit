// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
  a_method: return 42

mixin MixB extends A:
  b_method: return 42

class B extends MixB:
  b_method: return 42

mixin NonAbstractMixin:
  abstract foo x y -> int

main:
