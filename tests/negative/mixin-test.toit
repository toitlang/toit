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

mixin MixC extends:

interface I1:

mixin MixD extends implements I1:

class C with MixD:

class D extends Object with implements I1:

some_method:

class ClassB extends Object with ClassA UnknownMixin some_method:

mixin MixE extends Object with MixD:

mixin MixF extends MixE with B:

main:
