// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  test_simple
  test_try

test_simple:
  always_return
  maybe_return

test_try:
  stop_unwinding
  stop_unwinding_alternative

always_return:
  invoke: return 42
  unreachable

maybe_return:
  invoke: if pick: return 42
  return "hest"

stop_unwinding:
  x/any := 42
  try:
    x = null
    x = 3.3
    invoke: return "hest"
    x = true
  finally:
    return x

stop_unwinding_alternative:
  x/any := 42
  try:
    x = 3.3
    invoke: if pick: return "hest"
    x = true
  finally:
    return x

pick:
  return (random 100) < 50

invoke [block]:
  return block.call
