// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// Tests `yield` and the waits in monitors, alone and with other tasks.

main:
  test-round-robin
  test-alone-handles-messages
  test-alone-runs-resumed-task
  test-wait-alone
  test-wait-with-yielding-task

// Running tasks take turns in the order in which they were started.
test-round-robin:
  log := []
  task::
    3.repeat:
      log.add "a$it"
      yield
  task::
    3.repeat:
      log.add "b$it"
      yield
  3.repeat:
    log.add "main$it"
    yield
  expect-equals ["main0", "a0", "b0", "main1", "a1", "b1", "main2", "a2", "b2"] log
  // Let the tasks finish.
  yield
  yield

class FlagHandler implements SystemMessageHandler_:
  static TYPE ::= 998
  handled := false

  on-message type/int gid/int pid/int message/any -> none:
    handled = true

// A yield of the only running task handles the pending messages.
test-alone-handles-messages:
  handler := FlagHandler
  set-system-message-handler_ FlagHandler.TYPE handler
  try:
    expect (process-send_ Process.current.id FlagHandler.TYPE null)
    yield
    expect handler.handled
  finally:
    clear-system-message-handler_ FlagHandler.TYPE

// A task that the message processing of a yield resumes runs in that yield,
// even when the yielding task was the only running task before.
test-alone-runs-resumed-task:
  ran := false
  sleeper := task::
    // No yield when the sleep ends: the task runs to its end at once.
    critical-do: sleep --ms=10
    ran = true
  sleeper-impl := sleeper as Task_
  yields := 0
  while not ran:
    yield
    yields++
    // The sleeper only becomes a running task again when this task handles
    // the timer's message in a yield. It must have run before that yield
    // returned.
    expect (ran or sleeper-impl.state_ != Task_.STATE-RUNNING)
  expect yields > 1

// A wait of the only task ends when the message processing resumes it.
test-wait-alone:
  start := Time.monotonic-us
  sleep --ms=10
  expect Time.monotonic-us - start >= 10_000

// A wait ends when another task, which yields, resumes it through the
// message processing.
test-wait-with-yielding-task:
  stop := false
  yields := 0
  task::
    while not stop:
      yield
      yields++
  sleep --ms=10
  stop = true
  expect yields > 0
  yield
