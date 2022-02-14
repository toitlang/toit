// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/// This test wants to have no warnings.

use x:

test1 x -> int:
  while true:
    if x: break
    return 499

test2 x -> int:
  while true:
    if x: continue
    break

test3 x -> int:
  local := ?
  while true:
    if x:
      local = 42
    break
  return local

returns_true x: return true

test4 x:
  local := ?
  done := false
  for ; true; done = returns_true local:
    if done: break
    if x:
      continue
    local = 42

test5 x:
  local := ?
  done := false
  while true:
    if done: break
    if x:
      local = 42
      done = true
      continue
  return local

test6 x y z:
  local := ?
  while true:
    if x:
      local = 1
      break
    if y:
      local = 2
      break
    if z:
      break
  return local

run [block]: block.call

test7:
  local := ?
  while true:
    run: break
  return local

test8:
  local := ?
  run:
    while true:
      continue.run
  return local

main:
  test1 true
  test2 true
  test3 true
  test4 true
  test5 true
  test6 false false false
  test7
  test8
  unresolved
