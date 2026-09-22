// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.attribute-server as server
import expect show *

main:
  prepared-timeout
  with-timeout --ms=5_000:
    database := server.Database
    database.add-service #[0xf0, 0xff]
    database.add-characteristic #[0xf1, 0xff] --read --write --validate-write --value=#[1]
    database.add-characteristic #[0xf2, 0xff] --read --write --validate-write --value=#[2]
    session := database.session
    expect-equals #[1, 0x12, 3, 0, 0x0e] (session.request #[0x12, 3, 0, 42])
    expect-equals #[1] (database.value 3)
    saved/server.WriteRequest? := null
    response := validate session #[0x12, 3, 0, 42]: | request/server.WriteRequest |
      saved = request
      expect-equals 3 request.handle
      expect-equals 0x12 request.opcode
      expect-equals #[42] request.value
      expect-equals #[1] (database.value 3)
      request.value[0] = 99
      request.accept
      expect-throw "GATT_ALREADY_REPLIED": request.accept
    expect-equals #[0x13] response
    expect-equals #[42] (database.value 3)
    expect-throw "GATT_REQUEST_EXPIRED": saved.accept
    response = validate session #[0x12, 3, 0, 43]: | request/server.WriteRequest |
      request.reject 0x80
    expect-equals #[1, 0x12, 3, 0, 0x80] response
    expect-equals #[42] (database.value 3)
    response = validate session #[0x12, 3, 0, 44]: throw "APPLICATION_FAILED"
    expect-equals #[1, 0x12, 3, 0, 0x0e] response
    slow := server.Session database --handler-timeout=(Duration --ms=5)
    response = validate slow #[0x12, 3, 0, 45]: | request/server.WriteRequest |
      saved = request
      sleep --ms=100
      request.accept
    expect-equals #[1, 0x12, 3, 0, 0x0e] response
    expect-throw "GATT_REQUEST_EXPIRED": saved.accept
    expect-equals #[42] (database.value 3)
    // Preparation does not invoke validation or modify either attribute.
    validate session #[0x16, 3, 0, 0, 0, 50]: unreachable
    validate session #[0x16, 3, 0, 1, 0, 51]: unreachable
    validate session #[0x16, 5, 0, 0, 0, 60]: unreachable
    calls := 0
    response = validate session #[0x18, 1]: | request/server.WriteRequest |
      calls++
      expect-equals 0x18 request.opcode
      expect-equals #[42] (database.value 3)
      expect-equals #[2] (database.value 5)
      if request.handle == 3:
        expect-equals #[50, 51] request.value
        request.accept
      else:
        request.reject 0x81
    expect-equals 2 calls
    expect-equals #[1, 0x18, 5, 0, 0x81] response
    expect-equals #[42] (database.value 3)
    expect-equals #[2] (database.value 5)
    expect-equals #[0x19] (validate session #[0x18, 1]: unreachable)
    session.request #[0x16, 3, 0, 0, 0, 70]
    session.request #[0x16, 5, 0, 0, 0, 80]
    response = validate session #[0x18, 1]: | request/server.WriteRequest | request.accept
    expect-equals #[0x19] response
    expect-equals #[70] (database.value 3)
    expect-equals #[80] (database.value 5)

prepared-timeout:
  with-timeout --ms=2_000:
    database := server.Database
    database.add-service #[0xf0, 0xff]
    first := database.add-characteristic #[0xf1, 0xff] --read --write --validate-write --value=#[1]
    second := database.add-characteristic #[0xf2, 0xff] --read --write --validate-write --value=#[2]
    session := database.session --handler-timeout=(Duration --ms=20)
    saved/server.WriteRequest? := null
    try:
      session.request #[0x16, first, 0, 0, 0, 41]
      session.request #[0x16, second, 0, 0, 0, 42]
      calls := 0
      response := validate session #[0x18, 1]: | request/server.WriteRequest |
        calls++
        expect-equals #[1] (database.value first)
        expect-equals #[2] (database.value second)
        if calls == 2:
          saved = request
          sleep --ms=100
        request.accept
      expect-equals 2 calls
      expect-equals #[1, 0x18, saved.handle, 0, 0x0e] response
      expect-throw "GATT_REQUEST_EXPIRED": saved.accept
      expect-equals #[1] (database.value first)
      expect-equals #[2] (database.value second)
      session.writes-do: | _ _ | unreachable
      // The expired transaction is consumed; it cannot later commit or emit
      // accepted-write callbacks, even though its first validator approved.
      expect-equals #[0x19] (validate session #[0x18, 1]: unreachable)
      session.writes-do: | _ _ | unreachable
      session.request #[0x16, first, 0, 0, 0, 51]
      session.request #[0x16, second, 0, 0, 0, 52]
      expect-equals #[0x19] (validate session #[0x18, 1]: it.accept)
      expect-equals #[51] (database.value first)
      expect-equals #[52] (database.value second)
      accepted := {:}
      session.writes-do: | handle/int value/ByteArray |
        expect (not (accepted.contains handle))
        accepted[handle] = value
      expect-equals 2 accepted.size
      expect-equals #[51] accepted[first]
      expect-equals #[52] accepted[second]
    finally:
      session.close

validate session/server.Session pdu/ByteArray [handler] -> ByteArray?:
  return session.request pdu (: | read/server.ReadRequest | unreachable) handler
