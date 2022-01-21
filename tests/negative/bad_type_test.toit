// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import math as prefix

foo -> extends: return unresolved
foo x -> prefix.implements: return unresolved
bar -> extends.A: return unresolved
bar x -> prefix.implements.A: return unresolved

class A extends extends:
class B extends implements:

class A2 extends prefix.extends.A:
class B2 extends prefix.implements.B:

main:
  foo
  foo 499
