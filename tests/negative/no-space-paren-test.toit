// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

global := foo(3)

foo x:
  return x

bar x y:

gee:

main:
  local := 499
  foo(local)
  foo("str")
  bar local(499)
  foo foo(42)
  bar(local) 3
  foo([1, 2, 3])
  gee()
  unresolved
