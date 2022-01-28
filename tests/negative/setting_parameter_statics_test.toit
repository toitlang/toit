// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

x := 9
foo .x:
  unresolved

class A:
  z := 0
  static y := 0

  static bar .y:
    unresolved

  static gee .z:
    unresolved

main:
  foo 19
  A.bar 20
  A.gee 99
