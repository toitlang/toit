// Copyright (C) 2019 Toitware ApS. All rights reserved.

foo [block]:
  block.call 499

main:
  assert: true
  assert: 1 == 1
  foo: assert: it == 499
