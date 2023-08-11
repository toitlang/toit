// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import monitor

main:
  expect-equals 10 (thread:: test-send 10).join
  expect-equals 42 (thread:: test-send 42).join
  test-misc
  test-fib

test-send n:
  received := 0
  split := n >> 1

  channel := monitor.Channel split
  sender := thread::
    for i := 0; i < n; i++:
      channel.send i
      yield
    null

  for i := 0; i < split; i++:
    expect-equals i channel.receive
    received++

  // Force the remaining messages to be buffered by
  // delaying the receiver thread until the sender
  // thread is done.
  expect-null sender.join

  for i := split; i < n; i++:
    expect-equals i channel.receive
    received++
  return received

test-misc:
  channel := monitor.Channel 8
  thread::
    channel.send 42
  thread::
    channel.send 99
  expect-equals 42 channel.receive
  expect-equals 99 channel.receive

  master := thread::
    87
  5.repeat:
    thread::
      channel.send master.join
  5.repeat:
    expect-equals 87 channel.receive
  expect-equals 87 master.join

test-fib:
  expect-equals 1 (fib-join 1)
  expect-equals 1 (fib-join 2)
  expect-equals 5 (fib-join 5)
  expect-equals 55 (fib-join 10)

  expect-equals 1 (fib-channel 1)
  expect-equals 1 (fib-channel 2)
  expect-equals 5 (fib-channel 5)
  expect-equals 55 (fib-channel 10)

fib-join n:
  if n <= 2: return 1
  t1 := thread:: fib-join n - 1
  t2 := thread:: fib-join n - 2
  return t1.join + t2.join

fib-channel n:
  if n <= 2: return 1
  channel := monitor.Channel 8
  thread:: channel.send (fib-channel n - 1)
  thread:: channel.send (fib-channel n - 2)
  return channel.receive + channel.receive

// ----------------------------------------------------------------------------

thread code:
  result := Thread
  task:: result.complete code.call
  return result

monitor Thread:
  // Join support.
  is-done_ := false
  result_ := null

  join:
    await: is-done_
    return result_

  complete result:
    expect (not is-done_)
    result_ = result
    is-done_ = true
