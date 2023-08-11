// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo [block]:
  block.call 499

main:
  assert: true
  assert: 1 == 1
  foo: assert: it == 499
