// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/// This test wants to have no warnings.

import expect show *

use x:

test1 -> int:
  while true:
    return 499

test2 x -> int:
  while true:
    if x:
      return 499

test3 x -> int:
  local := ?
  while true:
    if x: return 42
  use local  // Dead code.

test4 x:
  local := ?
  while true:
    if x:
      local = 42
      break
  return local

test5 x:
  local := ?
  while true:
    if x: continue
    local = 42
    break
  return local

test6 x y -> int:
  local := ?
  while true:
    if x:
      local = 499
      break
    else if y:
      local = 42
      break
    else:
      local = 199
    break
  return local

returns-true x: return true
test7 x:
  local := ?
  done := false
  for ; true; done = returns-true local:
    if x:
      local = 499
    else:
      local = 199
    if done: break
  return local

test8 x:
  local := ?
  done := false
  for ; true; done = returns-true local:
    if x and not done:
      local = 42
      continue
    local = 11
    if done: break
  return local

test9 x y:
  local1 := ?
  while true:
    local2 := ?
    while true:
      if y:
        local2 = 42
        break
    if x:
      local1 = local2
      break
  return local1

run [block]: block.call

test10:
  local := ?
  while true:
    run: return 499
  return local

test11:
  local := ?
  while true:
    run:
      local = 499
      break
  return local

test12 x:
  local := ?
  done := false
  for ; true; done = returns-true local:
    run:
      if x and not done:
        local = 42
        continue
      local = 11
      if done: break
    unreachable
  return local

main:
  expect-equals 499 test1
  expect-equals 499 (test2 true)
  expect-equals 42  (test3 true)
  expect-equals 42  (test4 true)
  expect-equals 42  (test5 false)
  expect-equals 499 (test6 true false)
  expect-equals 42  (test6 false true)
  expect-equals 199 (test6 false false)
  expect-equals 499 (test7 true)
  expect-equals 11  (test8 true)
  expect-equals 42  (test9 true true)
  expect-equals 499 test10
  expect-equals 499 test11
  expect-equals 11  (test12 true)
