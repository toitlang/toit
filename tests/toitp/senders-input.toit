// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

the-target: return null

class A:
  foo: the-target

global-lazy-field := the-target

global-fun:
  the-target

main:
  (A).foo
  global-lazy-field
  global-fun
