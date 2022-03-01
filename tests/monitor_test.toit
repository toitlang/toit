// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import monitor show *

main:
  run
  with_timeout --ms=10_000: run
  run
  test_channel

run:
  test_simple_monitor
  test_yield_a_lot_in_monitor
  test_method_wake_up_1
  test_method_wake_up_2
  test_method_wake_up_3
  test_method_throw
  test_await_throw
  test_await_multiple
  test_fairness
  test_entry_timeouts

monitor A:
  foo_ready := false
  bar_ready := false

  foo_count := 0
  bar_count := 0

  foo:
    await: foo_count++; foo_ready

  bar:
    await: bar_count++; bar_ready

  baz [block]:
    block.call this

  foz [block]:
    await: block.call this

test_await_throw:
  a := A

  task_with_deadline::
    a.foo
    expect_equals 4 a.foo_count

  yield_a_lot

  a.foz: true

  yield_a_lot

  catch:
    a.foz:
      throw "OUT"

  yield_a_lot

  a.baz:
    a.foo_ready = true

test_method_throw:
  a := A

  task_with_deadline::
    a.foo
    expect_equals 3 a.foo_count

  yield_a_lot

  task_with_deadline::
    a.bar
    expect_equals 4 a.bar_count

  yield_a_lot

  catch:
    a.baz:
      a.foo_ready = true
      throw "OUT"

  yield_a_lot

  a.baz:
    a.bar_ready = true

test_method_wake_up_3:
  a := A

  a.foo_ready = true

  a.foo
  expect_equals 1 a.foo_count

test_method_wake_up_2:
  a := A

  task_with_deadline::
    a.foo
    expect_equals 2 a.foo_count

  yield_a_lot
  a.baz: it.foo_ready = true

test_method_wake_up_1:
  a := A

  task_with_deadline::
    a.foo
    expect_equals 3 a.foo_count

  yield_a_lot

  task_with_deadline::
    a.bar
    expect_equals 2 a.bar_count

  yield_a_lot

  a.baz:
    it.foo_ready = true
    it.bar_ready = true

test_await_multiple:
  a := A
  c := 2

  task_with_deadline::
    a.foz: c == 1
    a.baz: c = 0

  yield_a_lot

  a.baz: c = 1
  a.foz: c == 0

test_simple_monitor:
  // Validate that only one foo runs.
  m := MyMonitor
  task_with_deadline::
    m.foo true
  m.foo false

test_yield_a_lot_in_monitor:
  m := MyMonitor
  5.repeat:
    task::
      m.with_yield
  5.repeat:
    m.notify_
    yield

monitor MyMonitor:
  ran := false

  foo expect:
    expect_equals expect ran
    for i := 0; i < 20; i++:
      yield_a_lot
      sleep --ms=1
    ran = true

  with_yield:
    yield

yield_a_lot:
  10.repeat: yield

task_with_deadline lambda:
  deadline := task.deadline
  if deadline:
    task::
      task.with_deadline_ deadline:
        lambda.call
  else:
    task::
      lambda.call

test_fairness:
  mutex := Mutex
  counts := List 4: 0
  stop := Time.monotonic_us + 1 * 1_000_000
  done := Semaphore
  counts.size.repeat: | n |
    task::
      while Time.monotonic_us < stop:
        mutex.do:
          counts[n]++
          yield
      done.up
  counts.size.repeat: done.down
  // Check that the counts are fairly distributed.
  sum := 0
  counts.do: sum += it
  average := sum / counts.size
  counts.do:
    diff := it - average
    expect (diff.abs < 10)

test_entry_timeouts:
  mutex := Mutex
  ready := Semaphore
  done := Semaphore
  value := 0
  // Create a task that owns the mutex for a while.
  task::
    mutex.do:
      ready.up
      sleep --ms=300
  // Try to get hold of the mutex. Make sure it times
  // out as expected.
  ready.down
  10.repeat:
    task::
      expect_throw DEADLINE_EXCEEDED_ERROR:
        with_timeout --ms=10:
          mutex.do:
            value++
      done.up
  // Check that we get the timeouts before the mutex is
  // released, so the error isn't reported very late.
  10.repeat: done.down
  expect_throw DEADLINE_EXCEEDED_ERROR:
    with_timeout --ms=5:
      mutex.do:
        unreachable
  // Make sure nobody messed with the proctected value.
  expect_equals 0 value

test_channel:
  channel := Channel 5
  task:: channel_sender channel
  task:: channel_receiver channel

channel_sender channel/Channel:
  channel.send "Foo"
  channel.send "Bar"
  channel.send "Baz"
  channel.send "Boo"

channel_receiver channel/Channel:
  expect_equals "Foo"
    channel.receive
  sleep --ms=200
  str := channel.receive
  while next := channel.receive --blocking=false:
    str += next
  expect_equals "BarBazBoo" str
