// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import monitor

main:
  expect_equals 10 (thread:: test_send 10).join
  expect_equals 42 (thread:: test_send 42).join
  test_misc
  test_fib

test_send n:
  received := 0
  split := n >> 1

  channel := monitor.Channel split
  sender := thread::
    for i := 0; i < n; i++:
      channel.send i
      yield
    null

  for i := 0; i < split; i++:
    expect_equals i channel.receive
    received++

  // Force the remaining messages to be buffered by
  // delaying the receiver thread until the sender
  // thread is done.
  expect_null sender.join

  for i := split; i < n; i++:
    expect_equals i channel.receive
    received++
  return received

test_misc:
  channel := monitor.Channel 8
  thread::
    channel.send 42
  thread::
    channel.send 99
  expect_equals 42 channel.receive
  expect_equals 99 channel.receive

  master := thread::
    87
  5.repeat:
    thread::
      channel.send master.join
  5.repeat:
    expect_equals 87 channel.receive
  expect_equals 87 master.join

test_fib:
  expect_equals 1 (fib_join 1)
  expect_equals 1 (fib_join 2)
  expect_equals 5 (fib_join 5)
  expect_equals 55 (fib_join 10)

  expect_equals 1 (fib_channel 1)
  expect_equals 1 (fib_channel 2)
  expect_equals 5 (fib_channel 5)
  expect_equals 55 (fib_channel 10)

fib_join n:
  if n <= 2: return 1
  t1 := thread:: fib_join n - 1
  t2 := thread:: fib_join n - 2
  return t1.join + t2.join

fib_channel n:
  if n <= 2: return 1
  channel := monitor.Channel 8
  thread:: channel.send (fib_channel n - 1)
  thread:: channel.send (fib_channel n - 2)
  return channel.receive + channel.receive

// ----------------------------------------------------------------------------

thread code:
  result := Thread
  task:: result.complete code.call
  return result

monitor Thread:
  // Join support.
  is_done_ := false
  result_ := null

  join:
    await: is_done_
    return result_

  complete result:
    expect (not is_done_)
    result_ = result
    is_done_ = true
