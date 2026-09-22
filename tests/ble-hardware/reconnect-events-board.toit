// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.esp32
import .fixtures.vhci-reconnect as fixture
import .connection-events as events

main:
  recorder/events.ConnectionEvents? := null
  cycle := -1
  try:
    fixture.run-with-transport --cycles=1000 --warmup=3 --numbered-cycles
        --receive-acl-packets=4:
      cycle++
      recorder = events.ConnectionEvents esp32.Esp32Transport
      recorder
  finally:
    // The server has joined its controller reader before this scope exits.
    // Only the final cycle is retained; timestamps are local to this board.
    if recorder:
      print "BOARD_CONNECTION_EVENTS cycle=$cycle"
      recorder.dump
