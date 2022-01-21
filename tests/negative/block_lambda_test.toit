// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  b := (: |[x]| x.call)
  l := (:: |[x]| x.call)
  b2 := (: |this.x| x)
  l2 := (:: |this.x| x)
  b3 := (: |.x| x)
  l3 := (:: |.x| x)
  b4 := (: |--x| x)
  l4 := (:: |--x| x)
  unresolved
