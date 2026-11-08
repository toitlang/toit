// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import monitor

main:
  // Timers order tasks by their deadlines.
  order := []
  latch := monitor.Latch
  task::
    sleep --ms=30
    order.add "slow"
    if order.size == 3: latch.set true
  task::
    sleep --ms=10
    order.add "fast"
    if order.size == 3: latch.set true
  task::
    sleep --ms=20
    order.add "medium"
    if order.size == 3: latch.set true
  latch.get
  print order

  // with-timeout fires when the block takes too long.
  result := catch:
    with-timeout --ms=5:
      sleep --ms=100
  print result

  start := Time.monotonic-us
  sleep --ms=50
  elapsed := Time.monotonic-us - start
  print (elapsed >= 50_000)
