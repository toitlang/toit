// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo x / none:

class A:
  field / none := 0
  constructor field / none:

  instance x / none:
  static statik x / none:

main:
  foo null
  a := A null
  a.instance null
  A.statik null

