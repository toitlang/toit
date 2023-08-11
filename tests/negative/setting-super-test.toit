// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class C extends A:
  foo .x: 42

class A:
  x / int := 0

class B extends A:
  foo .x: 499

main:
  (B).foo "str"
  (C).foo "str"
