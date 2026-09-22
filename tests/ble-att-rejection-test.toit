// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import ble.experimental.attribute-server as server

main:
  database := server.Database --value-limit=512
  database.add-service #[0xf0, 0xff]
  handle := database.add-characteristic #[0xf1, 0xff]
      --read
      --write
      --write-command
      --validate-write
      --value=#[7]
  // Exercise all opcode/length pairs around the default MTU, targeting the
  // writable value. The default validator rejects every application write.
  256.repeat: | opcode/int |
    session := database.session
    try:
      27.repeat: | length/int |
        packet := ByteArray length --initial=0
        if length > 0: packet[0] = opcode
        if length > 1: packet[1] = handle
        check-request session database handle packet
    finally:
      session.close

  // A valid prepared write must remain uncommitted after malformed Execute
  // requests. A later well-formed Execute still goes through validation; its
  // refusal clears the transaction rather than applying any queued prefix.
  session := database.session
  try:
    expect-equals #[0x17, handle, 0, 0, 0, 42]
        session.request #[0x16, handle, 0, 0, 0, 42]
    [#[0x18], #[0x18, 2], #[0x18, 1, 0]].do: | packet/ByteArray |
      expect-equals #[1, 0x18, 0, 0, 4] (session.request packet)
      expect-equals #[7] (database.value handle)
    expect-equals #[1, 0x18, handle, 0, 0x0e] (session.request #[0x18, 1])
    expect-equals #[7] (database.value handle)
    expect-equals #[0x19] (session.request #[0x18, 1])
    session.writes-do: unreachable
  finally:
    session.close

check-request session/server.Session database/server.Database handle/int packet/ByteArray:
  result/ByteArray? := null
  failure := catch: result = session.request packet
  if packet.is-empty:
    expect-equals "ATT_INVALID_PDU" failure
  else:
    expect-null failure
    if packet[0] & 0x40 != 0: expect-null result
    else:
      expect (result != null and 1 <= result.size <= 23)
      if result[0] == 1:
        expect-equals 5 result.size
        expect-equals packet[0] result[1]
  expect-equals #[7] (database.value handle)
  session.writes-do: unreachable
