// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  test_break
  test_continue
  test_nested

test_break:
  x/any := 42
  while true:
    invoke:
      x = "hest"
      break
  id x

test_continue:
  x/any := 42
  while true:
    invoke:
      x = "hest"
      if pick: continue
      x = 3.3
      break
  id x

test_nested:
  invoke:
    while true:
      invoke:
        break

id x:
  return x

pick:
  return (random 100) < 50

invoke [block]:
  block.call
