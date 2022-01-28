// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
  static global := (A).foo
  foo: return global

bar x:

main:
  // Accessing `global` leads to an exception complaining that the variable
  // is being initialized.
  bar A.global
