// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor

// Without callbacks running in their own task, this test does not fail but
// hangs: the process spins, unable to process the messages that would wake
// it up, including the ones for timeouts.
main:
  test-blocking-callback
  test-sequential-callbacks
  test-dispose-in-callback

/**
A callback that blocks must not stop the process from handling messages.

The callback sleeps, which needs a timer notification. When callbacks ran
  inline in the message processing loop, that notification was never
  processed and the process spun forever.
*/
test-blocking-callback:
  with-timer: | state/monitor.ResourceState_ timer/Timer_ |
    called := monitor.Latch
    state.set-callback:: | bits/int |
      sleep --ms=1
      called.set bits
    fire timer
    with-timeout --ms=5_000:
      expect-equals 1 called.get

/** Callbacks for one resource run in order and never concurrently. */
test-sequential-callbacks:
  with-timer: | state/monitor.ResourceState_ timer/Timer_ |
    calls := 0
    running := false
    entered := monitor.Latch
    release := monitor.Latch
    done := monitor.Channel 10
    state.set-callback:: | bits/int |
      expect-not running
      running = true
      calls++
      if calls == 1:
        entered.set true
        release.get
      running = false
      done.send calls
    fire timer
    with-timeout --ms=5_000:
      entered.get
      fire timer
      // Give a second callback the chance to run concurrently.
      sleep --ms=50
      expect-equals 1 calls
      release.set true
      expect-equals 1 done.receive
      expect-equals 2 done.receive

/**
A callback can dispose its state, like the WiFi module does, and is not
  called again, even for a notification that arrived while it ran.
*/
test-dispose-in-callback:
  with-timer: | state/monitor.ResourceState_ timer/Timer_ |
    calls := 0
    disposed := monitor.Latch
    state.set-callback:: | bits/int |
      calls++
      // Fire again and wait for the notification, so another call is
      // pending when the state is disposed.
      fire timer
      while not state.callback-pending_: sleep --ms=1
      state.dispose
      disposed.set true
    fire timer
    with-timeout --ms=5_000:
      disposed.get
      // Give a pending call the chance to run.
      sleep --ms=50
      expect-equals 1 calls

// A $monitor.ResourceState_ needs a real VM resource, whose notifications
// arrive through the message queue. Timers exist on all platforms and their
// event source sets bit 0 (value 1) of the state when they fire.
with-timer [block]:
  timer := Timer_
  state := monitor.ResourceState_ timer-resource-group_ timer.timer_
  try:
    block.call state timer
  finally:
    state.dispose
    timer.close

fire timer/Timer_ -> none:
  timer.arm Time.monotonic-us  // Already due, so it fires right away.
