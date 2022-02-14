// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor

FOO := 42
BAR := 99
BAZ := List 2

exec [block]: return block.call

cyclic := foo_cyclic
foo_cyclic: return cyclic

parallel_global := yielding
parallel_latch := monitor.Latch
yielding:
  return parallel_latch.get

multi_attempt := try_multi_init
multi_init_counter := 0
try_multi_init:
  if multi_init_counter++ < 3: throw "not yet"
  return 42

main:
  expect_equals 42 FOO
  expect_equals 87 (exec: FOO = 87)
  expect_equals 87 FOO

  expect_equals 99 BAR
  expect_equals 123 (exec: BAR = 123)
  expect_equals 123 BAR
  expect_equals 87 FOO

  BAZ[0] = 3
  BAZ[1] = 7
  expect_equals (7 - 3) (BAZ[1] - BAZ[0])

  expect_throw "INITIALIZATION_IN_PROGRESS": cyclic

  task_started := monitor.Latch
  task_done := monitor.Latch
  task::
    task_started.set true
    expect_equals 499 parallel_global
    task_done.set true

  task_started.get
  expect_throw "INITIALIZATION_IN_PROGRESS": parallel_global
  parallel_latch.set 499
  expect task_done.get

  expect_throw "not yet": multi_attempt
  expect_throw "not yet": multi_attempt
  expect_throw "not yet": multi_attempt
  expect_equals 42 multi_attempt
