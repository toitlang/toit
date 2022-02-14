// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
  constructor .x:
    unresolved

  foo .x:
    unresolved

  static bar .x:
    unresolved

main:
  a := A 5
  a.foo 3
  A.bar 5
