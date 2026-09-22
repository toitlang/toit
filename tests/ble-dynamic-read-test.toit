// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.attribute-server as server
import expect show *
import monitor

main:
  with-timeout --ms=5_000:
    database := server.Database
    database.add-service #[0xf0, 0xff]
    database.add-characteristic #[0xf1, 0xff] --read --dynamic-read --value=#[8]
    session := database.session
    saved/server.ReadRequest? := null
    response := session.request #[0x0a, 3, 0]: | request/server.ReadRequest |
      saved = request
      expect-equals 3 request.handle
      expect-equals 0x0a request.opcode
      value := #[42]
      request.reply value
      value[0] = 99
      expect-throw "GATT_ALREADY_REPLIED": request.reply #[1]
    expect-equals #[0x0b, 42] response
    expect-equals #[8] (database.value 3)
    expect-throw "GATT_REQUEST_EXPIRED": saved.reply #[1]
    expect-equals #[1, 0x0a, 3, 0, 0x0e] (session.request #[0x0a, 3, 0])
    response = session.request #[0x0a, 3, 0]: | request/server.ReadRequest |
      request.reject 0x80
    expect-equals #[1, 0x0a, 3, 0, 0x80] response
    response = session.request #[0x0a, 3, 0]: throw "APPLICATION_FAILED"
    expect-equals #[1, 0x0a, 3, 0, 0x0e] response
    response = session.request #[8, 1, 0, 0xff, 0xff, 0xf1, 0xff]: | request/server.ReadRequest |
      expect-equals 8 request.opcode
      request.reply #[43]
    expect-equals #[9, 3, 3, 0, 43] response
    session.request #[4, 1, 0, 0xff, 0xff]: unreachable
    slow := server.Session database --handler-timeout=(Duration --ms=5)
    response = slow.request #[0x0a, 3, 0]: | request/server.ReadRequest |
      saved = request
      sleep --ms=100
      request.reply #[1]
    expect-equals #[1, 0x0a, 3, 0, 0x0e] response
    expect-throw "GATT_REQUEST_EXPIRED": saved.reply #[1]
    response = slow.request #[0x0a, 3, 0]: | request/server.ReadRequest | request.reply #[44]
    expect-equals #[0x0b, 44] response
    // A yielding handler does not block other Toit tasks.
    ticks := 0
    heartbeat := task::
      while true:
        sleep --ms=10
        ticks++
    try:
      response = session.request #[0x0a, 3, 0]: | request/server.ReadRequest |
        sleep --ms=250
        request.reply #[45]
      expect ticks >= 10
      expect-equals #[0x0b, 45] response
    finally:
      heartbeat.cancel
    started := monitor.Latch
    ended := monitor.Latch
    waiter := task::
      try:
        session.request #[0x0a, 3, 0]: | request/server.ReadRequest |
          saved = request
          started.set true
          sleep --ms=1000
          request.reply #[46]
      finally:
        critical-do --no-respect-deadline: ended.set true
    started.get
    waiter.cancel
    ended.get
    expect-throw "GATT_REQUEST_EXPIRED": saved.reply #[1]
    response = session.request #[0x0a, 3, 0]: | request/server.ReadRequest | request.reply #[47]
    expect-equals #[0x0b, 47] response
