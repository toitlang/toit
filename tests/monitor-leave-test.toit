// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor show *

/**
Tests the ways a monitor method can be left: the method must give the
  right result and the monitor must be unlocked exactly once, also when
  another task is waiting to enter.
*/

main:
  run
  with-timeout --ms=20_000: run

run:
  test-leave
  test-reentrant-call
  test-cancel-uncontended
  test-cancel-contended
  test-cancel-in-await
  test-timeout-in-await

monitor M:
  value_ := 0
  ready_ := false
  // Set by $leave-with-contender: a contending task waits for this
  //   latch before it tries to enter.
  go_/Latch? := null

  // Lets a contending task (if any) block on the monitor.
  enter_ -> none:
    if go_:
      go_.set true
      go_ = null
      10.repeat: yield

  hold entered/Latch release/Latch -> none:
    entered.set Task.current
    release.get

  ping -> int:
    return 499

  return-value x -> any:
    enter_
    return x

  return-in-branches x -> int:
    enter_
    if x:
      return 1
    else:
      return 2

  return-conditional x -> int:
    enter_
    return x ? 1 : 2

  return-in-loop -> int:
    enter_
    for i := 0; true; i++:
      if i == 3: return i
    unreachable

  return-nothing -> none:
    enter_
    value_++
    return

  fall-off-end:
    enter_
    value_++

  return-from-nested-block list/List:
    enter_
    list.do:
      if it > 1: return it
    return -1

  return-captured x -> int:
    enter_
    call-lambda:: x++
    return x

  call-block [block]:
    enter_
    block.call
    return -1

  throw-value:
    enter_
    throw "OUT"

  throw-from-nested-block:
    enter_
    [1].do: throw "OUT"

  return-wrong-type x/any -> int:
    enter_
    return x

  return-from-try-body:
    enter_
    try:
      return 5
    finally:
      value_++

  return-in-finally:
    enter_
    try:
      throw "OUT"
    finally:
      return 6

  return-in-finally-after-return:
    enter_
    try:
      return 5
    finally:
      return 6

  return-after-await:
    enter_
    ready_ = true
    await: ready_
    return 9

  return-try-await-result value/bool -> bool:
    enter_
    return try-await --deadline=(Time.monotonic-us + 1_000): value

  return-private-result:
    enter_
    return private-helper_ 10

  private-helper_ x:
    return x + 1

call-lambda lambda/Lambda:
  return lambda.call

caller-return m/M -> int:
  m.call-block: return 42
  return 0

caller-return-from-nested-block m/M -> int:
  m.call-block:
    [1, 2].do: if it == 2: return 43
  return 0

/**
Calls $leave (which enters $m through one of its methods) while another
  task is waiting to enter $m. Checks that the waiting task gets the
  monitor, that leaving does not unlock the monitor a second time while
  the waiting task holds it, and that the monitor is unlocked in the end.
*/
leave-with-contender m/M [leave]:
  go := Latch
  entered := Latch
  release := Latch
  done := Latch
  m.go_ = go
  task::
    go.get
    m.hold entered release
    done.set true
  leave.call
  contender := entered.get
  10.repeat: yield
  expect-identical contender m.owner_
  release.set true
  done.get
  expect-null m.owner_
  expect-equals 499 m.ping

check-leave [leave]:
  // Uncontended.
  m := M
  leave.call m
  expect-null m.owner_
  expect-equals 499 m.ping
  // With a task waiting to enter.
  m = M
  leave-with-contender m: leave.call m

test-leave:
  check-leave: expect-equals 42 (it.return-value 42)
  check-leave: expect-null (it.return-value null)
  check-leave: expect-equals 1 (it.return-in-branches true)
  check-leave: expect-equals 2 (it.return-in-branches false)
  check-leave: expect-equals 1 (it.return-conditional true)
  check-leave: expect-equals 2 (it.return-conditional false)
  check-leave: expect-equals 3 it.return-in-loop
  check-leave: | m/M |
    expect-null m.return-nothing
    expect-equals 1 m.value_
  check-leave: | m/M |
    expect-null m.fall-off-end
    expect-equals 1 m.value_
  check-leave: expect-equals 2 (it.return-from-nested-block [1, 2, 3])
  check-leave: expect-equals -1 (it.return-from-nested-block [1])
  check-leave: expect-equals 2 (it.return-captured 1)
  check-leave: expect-equals 42 (caller-return it)
  check-leave: expect-equals 43 (caller-return-from-nested-block it)
  check-leave: expect-equals -1 (it.call-block: null)
  check-leave: | m/M | expect-throw "OUT": m.throw-value
  check-leave: | m/M | expect-throw "OUT": m.throw-from-nested-block
  check-leave: expect-equals 3 (it.return-wrong-type 3)
  check-leave: | m/M |
    expect-not-null (catch: m.return-wrong-type "str")
  check-leave: | m/M |
    expect-equals 5 m.return-from-try-body
    expect-equals 1 m.value_
  check-leave: expect-equals 6 it.return-in-finally
  check-leave: expect-equals 6 it.return-in-finally-after-return
  check-leave: expect-equals 9 it.return-after-await
  check-leave: expect (it.return-try-await-result true)
  // Without a task waiting to enter: a timed-out await doesn't take the
  // monitor back before it returns.
  m := M
  expect-not (m.return-try-await-result false)
  expect-null m.owner_
  expect-equals 499 m.ping
  check-leave: expect-equals 11 it.return-private-result

monitor Reentrant:
  outer -> int:
    // Monitors are not reentrant: the inner call waits for the monitor
    // until the deadline.
    expect-throw DEADLINE-EXCEEDED-ERROR:
      with-timeout --ms=10: inner
    return 1

  inner -> int:
    return 2

test-reentrant-call:
  r := Reentrant
  expect-equals 1 r.outer
  expect-null r.owner_
  expect-equals 2 r.inner

test-cancel-uncontended:
  m := M
  done := Latch
  task::
    Task.current.cancel
    // A canceled task can't enter, not even an unlocked monitor.
    expect-throw CANCELED-ERROR: m.ping
    expect-null m.owner_
    // In a critical section it can.
    critical-do:
      expect-equals 499 m.ping
      expect-equals 42 (m.return-value 42)
    expect-null m.owner_
    critical-do: done.set true  // Canceled: needs a critical section.
  done.get
  expect-null m.owner_
  expect-equals 499 m.ping

test-cancel-contended:
  m := M
  entered := Latch
  release := Latch
  task:: m.hold entered release
  holder := entered.get
  waiting := Latch
  done := Latch
  waiter := task::
    waiting.set true
    expect-throw CANCELED-ERROR: m.ping
    critical-do: done.set true
  waiting.get
  10.repeat: yield
  waiter.cancel
  done.get
  // The canceled task did not take or release the monitor.
  expect-identical holder m.owner_
  release.set true
  10.repeat: yield
  expect-null m.owner_
  expect-equals 499 m.ping

monitor Waiting:
  never-ready -> any:
    await: false
    return 1

test-cancel-in-await:
  w := Waiting
  waiting := Latch
  done := Latch
  waiter := task::
    waiting.set true
    expect-throw CANCELED-ERROR: w.never-ready
    critical-do: done.set true
  waiting.get
  10.repeat: yield
  waiter.cancel
  done.get
  expect-null w.owner_

test-timeout-in-await:
  w := Waiting
  expect-throw DEADLINE-EXCEEDED-ERROR:
    with-timeout --ms=10: w.never-ready
  expect-null w.owner_
