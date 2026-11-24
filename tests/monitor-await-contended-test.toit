// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor

// Tests that a wait in a monitor method that ends with a timeout or a
// cancelation takes the monitor back before the method continues, even if
// another task owns the monitor at that point.

monitor Guarded:
  inside_ := 0
  max-inside_ := 0
  log_ := []
  flag_ := false  // Never set.

  enter_ name/string:
    inside_++
    max-inside_ = max max-inside_ inside_
    log_.add "$name in"

  leave_ name/string:
    log_.add "$name out"
    inside_--

  // Owns the monitor until $release gets a value.
  hold name/string release/monitor.Latch:
    enter_ name
    release.get
    leave_ name

  visit name/string:
    enter_ name
    leave_ name

  try-await-flag name/string --deadline/int? -> bool:
    enter_ name
    leave_ name
    result := try-await --deadline=deadline: flag_
    enter_ name
    yield
    leave_ name
    return result

  await-flag name/string:
    enter_ name
    leave_ name
    try:
      await: flag_
    finally:
      enter_ name
      yield
      leave_ name

/**
Lets task A call $wait on a new monitor, so that it waits.
Then lets task B own the monitor, while A's wait ends because of a timeout
  (A gets its deadline at $a-deadline) or because of a cancelation (if
  $cancel is true). Then lets task C wait to enter the monitor, and lets B
  leave.
Checks that A only continues after B has left, and that A and C never
  are in the monitor at the same time either.
*/
run-contended wait/Lambda --cancel/bool=false --a-deadline/int?=null -> List:
  m := Guarded
  release := monitor.Latch
  a-done := false
  b-done := false
  c-done := false
  a := task::
    try:
      wait.call m
    finally:
      a-done = true

  // Wait until A waits.
  wait-until: m.log_.size == 2
  task::
    m.hold "B" release
    b-done = true
  wait-until: m.inside_ == 1

  if cancel: a.cancel
  if a-deadline: wait-until: Time.monotonic-us > a-deadline
  // Give A the chance to run after its wait ended.
  sleep --ms=20
  expect-equals ["A in", "A out", "B in"] m.log_

  task::
    m.visit "C"
    c-done = true
  sleep --ms=10
  release.set null

  wait-until: a-done and b-done and c-done
  expect-equals 1 m.max-inside_
  expect-equals 0 m.inside_
  expect-equals "B out" m.log_[3]
  check-exclusive m.log_
  // The monitor is free again.
  with-timeout --ms=1_000: m.visit "D"
  return m.log_

check-exclusive log/List:
  expect log.size % 2 == 0
  for i := 0; i < log.size; i += 2:
    name := log[i][.. log[i].size - 3]
    expect-equals "$name in" log[i]
    expect-equals "$name out" log[i + 1]

wait-until [condition]:
  with-timeout --ms=10_000:
    while not condition.call: sleep --ms=1

main:
  test-try-await-deadline
  test-try-await-task-deadline
  test-await-task-deadline
  test-await-canceled
  test-try-await-canceled
  test-critical-try-await-deadline
  test-critical-await-task-deadline
  test-critical-canceled-try-await-deadline
  test-canceled-while-taking-back

test-try-await-deadline:
  result := null
  deadline := Time.monotonic-us + 20_000
  run-contended --a-deadline=deadline:: | m/Guarded |
    result = m.try-await-flag "A" --deadline=deadline
  expect-equals false result

test-try-await-task-deadline:
  result := null
  deadline := Time.monotonic-us + 20_000
  run-contended --a-deadline=deadline:: | m/Guarded |
    with-timeout --ms=20:
      result = m.try-await-flag "A" --deadline=null
  expect-equals false result

test-await-task-deadline:
  exception := null
  deadline := Time.monotonic-us + 20_000
  run-contended --a-deadline=deadline:: | m/Guarded |
    exception = catch:
      with-timeout --ms=20:
        m.await-flag "A"
  expect-equals DEADLINE-EXCEEDED-ERROR exception

test-await-canceled:
  after-await := false
  run-contended --cancel:: | m/Guarded |
    m.await-flag "A"
    after-await = true
  expect-not after-await

test-try-await-canceled:
  after-await := false
  run-contended --cancel:: | m/Guarded |
    m.try-await-flag "A" --deadline=null
    after-await = true
  expect-not after-await

test-critical-try-await-deadline:
  result := null
  deadline := Time.monotonic-us + 20_000
  run-contended --a-deadline=deadline:: | m/Guarded |
    critical-do:
      result = m.try-await-flag "A" --deadline=deadline
  expect-equals false result

test-critical-await-task-deadline:
  exception := null
  deadline := Time.monotonic-us + 20_000
  run-contended --a-deadline=deadline:: | m/Guarded |
    exception = catch:
      with-timeout --ms=20:
        critical-do:
          m.await-flag "A"
  expect-equals DEADLINE-EXCEEDED-ERROR exception

// A critical section ignores the cancelation, so the wait ends with the
// timeout. The cancelation stays pending and shows once the task leaves the
// critical section.
test-critical-canceled-try-await-deadline:
  result := null
  after-critical := false
  after-sleep := false
  deadline := Time.monotonic-us + 20_000
  run-contended --cancel --a-deadline=deadline:: | m/Guarded |
    critical-do:
      result = m.try-await-flag "A" --deadline=deadline
    after-critical = true
    sleep --ms=1
    after-sleep = true
  expect-equals false result
  expect after-critical
  expect-not after-sleep

// A times out, and gets canceled while it waits to take the monitor back.
test-canceled-while-taking-back:
  m := Guarded
  release := monitor.Latch
  result := null
  after-try-await := false
  after-sleep := false
  a-done := false
  deadline := Time.monotonic-us + 20_000
  a := task::
    try:
      result = m.try-await-flag "A" --deadline=deadline
      after-try-await = true
      sleep --ms=1
      after-sleep = true
    finally:
      a-done = true
  wait-until: m.log_.size == 2
  task:: m.hold "B" release
  wait-until: m.inside_ == 1
  wait-until: Time.monotonic-us > deadline
  sleep --ms=20
  a.cancel
  sleep --ms=10
  expect-equals ["A in", "A out", "B in"] m.log_
  release.set null
  wait-until: a-done
  expect-equals ["A in", "A out", "B in", "B out", "A in", "A out"] m.log_
  expect-equals 1 m.max-inside_
  expect-equals false result
  expect after-try-await
  expect-not after-sleep
