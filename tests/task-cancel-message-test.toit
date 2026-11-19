// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor show Latch

class CancelHandler implements SystemMessageHandler_:
  static TYPE ::= 999

  target_/Task_
  blocked-on_/Latch

  constructor .target_ .blocked-on_:

  on-message type/int gid/int pid/int message/any -> none:
    // The target entered a noncritical wait, but is now processing this message
    // in a critical region on its stack while this handler runs on another task.
    expect-not-identical target_ Task_.current
    expect-identical blocked-on_ target_.monitor_
    expect (target_.critical-count_ > 0)
    expect-equals Task_.STATE-SUSPENDING target_.state_

    target_.cancel

    // Check immediately, before another notification could hide a lost wakeup.
    expect-equals Task_.STATE-RUNNING target_.state_

main:
  done := Latch
  task::
    blocked-on := Latch
    handler := CancelHandler Task_.current blocked-on
    set-system-message-handler_ CancelHandler.TYPE handler
    try:
      // Sending to ourselves does not yield, so the message is processed when
      // this task suspends in the latch wait below.
      expect (process-send_ Process.current.id CancelHandler.TYPE null)
      expect-throw CANCELED-ERROR: blocked-on.get
      critical-do: done.set true
    finally:
      clear-system-message-handler_ CancelHandler.TYPE

  expect (with-timeout --ms=5_000: done.get)
