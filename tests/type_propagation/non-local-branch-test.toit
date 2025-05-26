// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  test-break
  test-break-in-try
  test-continue
  test-nested

test-break:
  x/any := 42
  while true:
    invoke:
      x = "hest"
      break
  id x

test-break-in-try:
  x/any := 42
  while true:
    try:
      break
    finally:
  id x

test-continue:
  x/any := 42
  while true:
    invoke:
      x = "hest"
      if pick: continue
      x = 3.3
      break
  id x

test-nested:
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
