// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.pairing-attempts as retry
import expect show *
import system
import monitor

main:
  test-cancel
  a := #[0, 1, 2, 3, 4, 5, 6]
  b := #[1, 1, 2, 3, 4, 5, 6]
  c := #[0, 6, 5, 4, 3, 2, 1]
  policy := make-policy
  now := 0
  [10, 20, 40, 80, 80].do: | delay/int |
    fail policy a now
    deny policy a (now + delay - 1)
    // Other typed identities remain independent.
    succeed policy b now
    now += delay
  succeed policy a now
  // Success preserves earlier history; two quiet periods halve80 to20.
  succeed policy a 470
  fail policy a 470
  deny policy a 509
  succeed policy a 510

  policy = make-policy
  fail policy a 0
  fail policy b 0
  expect-throw "SMP_PAIRING_HISTORY_FULL": succeed policy c 0
  deny policy a 9
  // Fully decayed histories may be reclaimed; never evict live penalties.
  succeed policy c 160

  policy = make-policy
  policy.with-attempt a --clock=(: 0):
    expect-throw "SMP_PAIRING_ALREADY_ACTIVE": succeed policy a 0
    policy.with-attempt b --clock=(: 0):
      expect-throw "SMP_PAIRING_HISTORY_FULL": succeed policy c 0
  succeed policy c 0

  policy = make-policy
  original := a.copy
  expect-throw "FAILED":
    policy.with-attempt a --clock=(: 0):
      a[1] ^= 0xff
      system.process-stats --gc
      throw "FAILED"
  deny policy original 9
  succeed policy a 0
  unwind policy c
  deny policy c 9

  [#[], ByteArray 6, ByteArray 8, #[2, 1, 2, 3, 4, 5, 6]].do: | invalid/ByteArray |
    expect-throw "INVALID_ARGUMENT": succeed policy invalid 0
  expect-throw "INVALID_ARGUMENT": retry.Attempts --capacity=0
  expect-throw "INVALID_ARGUMENT": retry.Attempts --minimum=(Duration --us=0)
  expect-throw "INVALID_ARGUMENT": retry.Attempts --maximum=(Duration --us=1)
  expect-throw "INVALID_ARGUMENT": retry.Attempts --decay=(Duration --s=1)

make-policy -> retry.Attempts:
  return retry.Attempts --capacity=2
      --minimum=(Duration --us=10)
      --maximum=(Duration --us=80)
      --decay=(Duration --us=160)

fail policy/retry.Attempts peer/ByteArray now/int:
  expect-throw "FAILED": policy.with-attempt peer --clock=(: now): throw "FAILED"

deny policy/retry.Attempts peer/ByteArray now/int:
  called := false
  expect-throw "SMP_REPEATED_ATTEMPTS": policy.with-attempt peer --clock=(: now): called = true
  expect (not called)

succeed policy/retry.Attempts peer/ByteArray now/int:
  called := false
  policy.with-attempt peer --clock=(: now): called = true
  expect called

unwind policy/retry.Attempts peer/ByteArray:
  policy.with-attempt peer --clock=(: 0): return
  unreachable

test-cancel:
  with-timeout --ms=1_000:
    policy := make-policy
    a := #[0, 1, 2, 3, 4, 5, 6]
    b := #[1, 1, 2, 3, 4, 5, 6]
    started := monitor.Latch
    never := monitor.Latch
    ended := monitor.Latch
    now := 0
    worker := task::
      try:
        policy.with-attempt a --clock=(: now):
          started.set true
          never.get
      finally:
        critical-do --no-respect-deadline: ended.set true
    try:
      started.get
      expect-throw "SMP_PAIRING_ALREADY_ACTIVE": succeed policy a now
      succeed policy b now
      now = 5
      worker.cancel
      ended.get
      // Charge the failure at cancellation, not at attempt start.
      deny policy a 14
      succeed policy a 15
    finally:
      worker.cancel
