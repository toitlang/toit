// Copyright (C) 2018 Toitware ApS. All rights reserved.

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
    c = 0

  yield_a_lot

  c = 1
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
    m.notify_all_
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
