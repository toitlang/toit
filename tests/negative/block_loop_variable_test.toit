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

  func := null
  while x := block:
    func = :: x

  y = 0
  for x := block; x.call; y++:
    func = :: x
