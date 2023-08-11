// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  test-simple
  test-try

test-simple:
  always-return
  maybe-return

test-try:
  stop-unwinding
  stop-unwinding-alternative

always-return:
  invoke: return 42
  unreachable

maybe-return:
  invoke: if pick: return 42
  return "hest"

stop-unwinding:
  x/any := 42
  try:
    x = null
    x = 3.3
    invoke: return "hest"
    x = true
  finally:
    return x

stop-unwinding-alternative:
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
