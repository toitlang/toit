// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

some-fun x: return x

test-with-return:
  local := ?
  if some-fun true:
    local = 499
  else:
    return
  expect-equals 499 local

main:
  local := ?
  local = 499
  expect-equals 499 local

  local2 := ?  // Ok, if not used.

  local3 := ?
  if some-fun true:
    local3 = 1
  else:
    local3 = 2
  expect-equals 1 local3

  local4 := ?
  if some-fun true:
    local4 = 499
  else:
    unreachable
  expect-equals 499 local4

  local5 := ?
  if some-fun true:
    local5 = 499
    expect-equals 499 local5

  local6 := ?
  if some-fun false:
    unreachable
  else:
    local6 = 42
  expect-equals 42 local6

  local7 := ?
  if some-fun true:
    local7 = 498
    if some-fun true:
      local7++
  else:
    local7 = -1
  expect-equals 499 local7

  local8 := ?
  (if true: local8 = 498 else: local8 = 42) and local8++
  expect-equals 499 local8

  local9 := ?
  (if true: local9 = some-fun false else: local9 = some-fun false) or (if true: local9 = 499)
  expect-equals 499 local9

  test-with-return
