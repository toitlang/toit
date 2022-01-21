// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  block := (: true)
  while x := block:
    print x
  y := 0
  for x := block; x.call; y++:
    print x

  fun := null
  while x := block:
    fun = :: x

  y = 0
  for x := block; x.call; y++:
    fun = :: x
