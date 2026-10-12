// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import i2s
import monitor

// The caller supplies a running slave bus with full transmit buffers and
// no external clocks. Controllers differ in whether stop clears TX buffers.
check-stop bus/i2s.Bus mode/string --restart-clears-tx/bool:
  workers := []
  finished := List 4: monitor.Latch
  results := List 4
  try:
    4.repeat: |index/int|
      workers.add (task::
        try:
          results[index] = catch:
            if index == 0:
              bus.write (ByteArray 64)
            else if index == 1:
              bus.try-write (ByteArray 64)
            else:
              bus.read (ByteArray 64)
        finally:
          critical-do --no-respect-deadline: finished[index].set true
      )
    sleep --ms=10
    finished.do: |latch/monitor.Latch| expect (not latch.has-value)
    if mode == "close":
      bus.close
    else:
      bus.stop
      if mode == "restart": bus.start
    with-timeout --ms=500:
      finished.do: it.get
    results.do: expect-equals (mode == "close" ? "CLOSED" : "INVALID_STATE") it
    if mode == "restart":
      // Old calls must not join this run, even though it started before
      // their tasks could observe stop. New calls use the fresh run.
      if restart-clears-tx:
        expect-equals 64 (bus.try-write (ByteArray 64))
      error := catch: with-timeout --ms=5: bus.read (ByteArray 64)
      expect-equals "DEADLINE_EXCEEDED" error
  finally:
    workers.do: it.cancel
