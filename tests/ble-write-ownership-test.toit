// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import system
import ble.experimental.attribute-server as server

main:
  [0x12, 0x52].do: | opcode/int |
    database := server.Database
    database.add-service #[0xf0, 0xff]
    handle := database.add-characteristic #[0xf1, 0xff]
        --read
        --write
        --write-command
        --validate-write
    session := database.session
    packet := #[opcode, handle, 0, 42]
    try:
      response := session.request packet
          (: | _ | unreachable)
          (: | request/server.WriteRequest |
            expect-equals #[42] request.value
            request.value[0] = 99
            packet[3] = 98
            system.process-stats --gc
            request.accept)
      expect-equals (opcode == 0x52 ? null : #[0x13]) response
      expect-equals #[42] (database.value handle)
      snapshot := database.value handle
      snapshot[0] = 97
      // Replacing database state cannot rewrite an undelivered accepted value.
      database.set-value handle #[88]
      retained/ByteArray? := null
      session.writes-do: | actual/int value/ByteArray |
        expect-equals handle actual
        expect-equals #[42] value
        retained = value
        value[0] = 96
      session.writes-do: | _ _ | unreachable
      system.process-stats --gc
      expect-equals #[96] retained
      expect-equals #[88] (database.value handle)
    finally:
      session.close
