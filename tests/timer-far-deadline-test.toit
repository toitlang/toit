// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

/**
Timers armed with deadlines far in the future (up to int.MAX microseconds)
  must not abort the VM.

The timer event source used to convert the remaining delay to nanoseconds
  without guarding against overflow, which produced an invalid timespec and
  a fatal error from pthread_cond_timedwait. Very negative deadlines made the
  delay computation overflow, so the timer event source waited (almost)
  forever and no other timer fired.
*/

DEADLINES ::= [
  0x7fff_ffff_ffff_ffff,
  0x7fff_ffff_ffff_ffff - 1_000_000,
  0x4000_0000_0000_0000,
  0x0020_0000_0000_0000,
  9_223_372_036_855_000,  // Just above int.MAX / 1000.
  int.MIN,
  -1,
]

main:
  group := timer-init_
  DEADLINES.do: | deadline |
    timer := timer-create_ group
    // Each timer becomes the first in the timer queue and is waited for
    // by the timer event source.
    timer-arm_ timer deadline
    sleep --ms=20
    timer-delete_ group timer

  // A sleeping task whose wakeup time is int.MAX.
  task := task::
    sleep (Duration --us=int.MAX - Time.monotonic-us)
  sleep --ms=20
  task.cancel

  // The timers must still work.
  start := Time.monotonic-us
  sleep --ms=10
  expect (Time.monotonic-us - start) >= 10_000

timer-init_:
  #primitive.timer.init

timer-create_ group:
  #primitive.timer.create

timer-arm_ timer usec:
  #primitive.timer.arm

timer-delete_ group timer:
  #primitive.timer.delete
