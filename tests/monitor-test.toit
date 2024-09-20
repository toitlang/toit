// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import monitor show *

main:
  run
  with-timeout --ms=10_000: run
  run
  test-channel
  test-semaphore

run:
  test-simple-monitor
  test-yield-a-lot-in-monitor
  test-method-wake-up-1
  test-method-wake-up-2
  test-method-wake-up-3
  test-method-throw
  test-await-throw
  test-await-multiple
  test-fairness
  test-entry-timeouts
  test-sleep-in-await
  test-block-in-await
  test-process-messages-in-locked
  test-yield-on-leave
  test-process-messages-on-leave
  test-gate
  test-latch
  test-signal

monitor A:
  foo-ready := false
  bar-ready := false

  foo-count := 0
  bar-count := 0

  foo:
    await: foo-count++; foo-ready

  bar:
    await: bar-count++; bar-ready

  baz [block]:
    block.call this

  foz [block]:
    await: block.call this

test-await-throw:
  a := A

  task-with-deadline::
    a.foo
    expect-equals 4 a.foo-count

  yield-a-lot

  a.foz: true

  yield-a-lot

  catch:
    a.foz:
      throw "OUT"

  yield-a-lot

  a.baz:
    a.foo-ready = true

test-method-throw:
  a := A

  task-with-deadline::
    a.foo
    expect-equals 3 a.foo-count

  yield-a-lot

  task-with-deadline::
    a.bar
    expect-equals 4 a.bar-count

  yield-a-lot

  catch:
    a.baz:
      a.foo-ready = true
      throw "OUT"

  yield-a-lot

  a.baz:
    a.bar-ready = true

test-method-wake-up-3:
  a := A

  a.foo-ready = true

  a.foo
  expect-equals 1 a.foo-count

test-method-wake-up-2:
  a := A

  task-with-deadline::
    a.foo
    expect-equals 2 a.foo-count

  yield-a-lot
  a.baz: it.foo-ready = true

test-method-wake-up-1:
  a := A

  task-with-deadline::
    a.foo
    expect-equals 3 a.foo-count

  yield-a-lot

  task-with-deadline::
    a.bar
    expect-equals 2 a.bar-count

  yield-a-lot

  a.baz:
    it.foo-ready = true
    it.bar-ready = true

test-await-multiple:
  a := A
  c := 2

  task-with-deadline::
    a.foz: c == 1
    a.baz: c = 0

  yield-a-lot

  a.baz: c = 1
  a.foz: c == 0

test-simple-monitor:
  // Validate that only one foo runs.
  m := MyMonitor
  task-with-deadline::
    m.foo true
  m.foo false

test-yield-a-lot-in-monitor:
  m := MyMonitor
  5.repeat:
    task::
      m.with-yield
  5.repeat:
    m.notify_
    yield

monitor MyMonitor:
  ran := false

  foo expect:
    expect-equals expect ran
    for i := 0; i < 20; i++:
      yield-a-lot
      sleep --ms=1
    ran = true

  with-yield:
    yield

yield-a-lot:
  10.repeat: yield

task-with-deadline lambda:
  deadline := Task_.current.deadline
  if deadline:
    task::
      Task_.current.with-deadline_ deadline:
        lambda.call
  else:
    task::
      lambda.call

test-fairness:
  mutex := Mutex
  counts := List 4: 0
  stop := Time.monotonic-us + 1 * 1_000_000
  done := Semaphore
  counts.size.repeat: | n |
    task::
      while Time.monotonic-us < stop:
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

test-entry-timeouts:
  mutex := Mutex
  ready := Semaphore
  done := Semaphore
  test-done := Semaphore
  value := 0
  // Create a task that owns the mutex for a while.
  task::
    mutex.do:
      ready.up
      test-done.down
  // Try to get hold of the mutex. Make sure it times
  // out as expected.
  ready.down
  10.repeat:
    task::
      expect-throw DEADLINE-EXCEEDED-ERROR:
        with-timeout --ms=10:
          mutex.do:
            value++
      done.up
  // Check that we get the timeouts before the mutex is
  // released, so the error isn't reported very late.
  10.repeat: done.down
  expect-throw DEADLINE-EXCEEDED-ERROR:
    with-timeout --ms=5:
      mutex.do:
        unreachable
  // Make sure nobody messed with the proctected value.
  expect-equals 0 value
  test-done.up

test-channel:
  channel := Channel 5
  sent := Latch
  done := Latch
  task:: channel-sender channel sent
  task:: channel-receiver channel sent done
  done.get

  // Test that the channel blocks at 5 entries.

  expect-equals 5 channel.capacity
  expect-equals 0 channel.size

  sent-count := 0
  task::
    10.repeat:
      channel.send it
      sent-count++

  while sent-count != 4: yield
  10.repeat: yield
  // There was still space for one number.
  expect-equals 5 sent-count
  expect-equals 5 channel.size

  10.repeat: channel.receive
  expect-equals 0 channel.size
  expect-equals 10 sent-count

  block-call-count := 0
  task::
    10.repeat: | val |
      channel.send:
        block-call-count++
        val

  while block-call-count != 4: yield
  10.repeat: yield
  // There was still space for one number.
  expect-equals 5 block-call-count
  expect-equals 5 channel.size

  10.repeat: channel.receive
  expect-equals 0 channel.size
  expect-equals 10 block-call-count

channel-sender channel/Channel latch/Latch:
  channel.send "Foo"
  channel.send "Bar"
  channel.send "Baz"
  channel.send "Boo"
  latch.set true

channel-receiver channel/Channel sent/Latch done/Latch:
  expect-equals "Foo"
    channel.receive
  sent.get
  str := channel.receive
  while next := channel.receive --blocking=false:
    str += next
  expect-equals "BarBazBoo" str
  done.set true

monitor Outer:
  block -> none:
    return

  locked ready/Latch done/Latch -> none:
    ready.set 0
    done.get

monitor Inner:
  sleep-in-await -> none:
    await:
      // The call to sleep sets a deadline on the current task, while it
      // already has a deadline set from the await call.
      sleep --ms=10
      false

  block-in-await outer/Outer -> none:
    await:
      // The call to outer.block sets a deadline on the current task, while it
      // already has a deadline set from the await call.
      expect-throw DEADLINE-EXCEEDED-ERROR: outer.block
      false

  non-blocking-call -> none:
    return

  non-blocking-await -> none:
    await: true

test-sleep-in-await:
  inner := Inner
  expect-throw DEADLINE-EXCEEDED-ERROR:
    with-timeout --ms=100:
      inner.sleep-in-await

test-block-in-await:
  done := Latch
  ready := Latch
  outer := Outer
  inner := Inner
  task:: outer.locked ready done
  ready.get  // Make sure outer is locked.
  expect-throw DEADLINE-EXCEEDED-ERROR:
    with-timeout --ms=100:
      inner.block-in-await outer
  done.set 0

class MessageHandler implements SystemMessageHandler_:
  static TYPE ::= 999
  static KIND-NON-BLOCKING-CALL ::= 0
  static KIND-NON-BLOCKING-AWAIT ::= 1
  static KIND-NO-DEADLINE ::= 2

  calls/int := 0
  inner/Inner ::= Inner

  on-message type/int gid/int pid/int message/List -> none:
    kind := message[0]
    // Calling the monitor methods will not block, but it might reuse
    // the deadline set in the task that ends up doing the message
    // processing and re-arm its timer, thus canceling future notifications.
    if kind == KIND-NON-BLOCKING-CALL:
      inner.non-blocking-call
    else if kind == KIND-NON-BLOCKING-AWAIT:
      inner.non-blocking-await
    else if kind == KIND-NO-DEADLINE:
      expect-null Task_.current.deadline
    calls++

test-process-messages-in-locked:
  test-process-messages-in-locked MessageHandler.KIND-NON-BLOCKING-CALL
  test-process-messages-in-locked MessageHandler.KIND-NON-BLOCKING-AWAIT
  test-process-messages-in-locked MessageHandler.KIND-NO-DEADLINE

test-process-messages-in-locked kind/int:
  handler := MessageHandler
  set-system-message-handler_ MessageHandler.TYPE handler
  done := Latch
  ready := Latch
  outer := Outer
  task:: outer.locked ready done
  ready.get  // Make sure outer is locked.

  // Enqueue a message for ourselves. Will be processed on
  // the current task after blocking on the call to outer.block.
  process-send_ Process.current.id MessageHandler.TYPE [kind]
  expect-equals 0 handler.calls

  expect-throw DEADLINE-EXCEEDED-ERROR:
    with-timeout --ms=100:
      expect-equals 0 handler.calls
      outer.block
      expect-equals 1 handler.calls
  done.set 0

test-yield-on-leave:
  output := []
  done := Latch
  task::
    20.repeat:
      yield
      output.add (Task.current)
    done.set null

  mutex := Mutex
  20.repeat:
    mutex.do: null  // Nothing.
    output.add (Task.current)

  done.get
  expect-equals 40 output.size

  // Check that the two tasks take turns
  // producing output.
  last := null
  output.do:
    expect-not-identical last it
    last = it

test-process-messages-on-leave:
  done := Latch
  task::
    sleep --ms=200
    done.set null

  // Check that leaving the mutex lock causes
  // us to process the messages necessary to
  // wake up the sleeping task.
  mutex := Mutex
  start := Time.monotonic-us
  end := start + 10_000_000
  while Time.monotonic-us < end and not done.has-value:
    mutex.do: null  // Do nothing.

  expect done.has-value --message="Task should be done" // Not starved.
  done.get

test-gate:
  gate := Gate

  2.repeat:
    task-is-running := Latch
    task-finished := false
    task::
      task-is-running.set true
      gate.enter
      task-finished = true

    expect gate.is-locked
    expect-not gate.is-unlocked

    task-is-running.get
    10.repeat: yield
    expect-not task-finished

    gate.unlock
    10.repeat: yield
    expect task-finished

    expect gate.is-unlocked

    gate.enter
    gate.lock
    expect gate.is-locked

test-latch:
  l1 := Latch
  task:: l1.set 42
  expect-equals 42 l1.get

  l2 := Latch
  task:: l2.set --exception 87
  expect-throw 87: l2.get

  l3 := Latch
  task::
    catch:
      try:
        throw 99
      finally: | is-exception exception |
        l3.set --exception exception
  expect-throw 99: l3.get

test-signal:
  done := Semaphore
  order := []
  signal := Signal
  t0 := false
  t1 := false
  t2 := false
  task::
    signal.wait: t0
    order.add 0
    done.up
  task::
    signal.wait: t1
    order.add 1
    done.up
  // Make sure we can raise the signal here without making
  // progress and without getting any of the tasks already
  // waiting stuck.
  signal.raise
  task::
    signal.wait: t2
    order.add 2
    done.up
  t0 = true
  signal.raise
  done.down
  t1 = true
  signal.raise
  done.down
  t2 = true
  signal.raise
  done.down
  expect-list-equals [0, 1, 2] order

test-semaphore:
  semaphore := Semaphore
  expect-equals 0 semaphore.count

  started := Latch
  done := false
  task::
    started.set true
    semaphore.down
    expect-equals 0 semaphore.count
    done = true

  started.get
  10.repeat: yield
  expect-not done
  semaphore.up
  10.repeat: yield
  expect done

  // Test limit, initial value and multiple ups/downs.
  semaphore = Semaphore --limit=3 --count=2
  started = Latch
  consume := Latch
  done = false
  task::
    started.set true
    consume.get
    5.repeat:
      // We wait for more than the limit.
      semaphore.down
    expect-equals 0 semaphore.count
    done = true

  started.get
  expect-equals 2 semaphore.count
  10.repeat:
    semaphore.up
  // Stops at the limit.
  expect-equals 3 semaphore.count
  consume.set true
  10.repeat: yield
  expect-equals 0 semaphore.count
  expect-not done
  semaphore.up
  semaphore.up
  10.repeat: yield
  expect done
