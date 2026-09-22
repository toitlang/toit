// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.attribute-server as server
import ble.experimental.security-state show SecurityState
import expect show *

class Evidence implements SecurityState:
  paired/bool := false
  encrypted/bool := false
  authenticated/bool := false

main:
  access
  handlers

access:
  database := server.Database
  database.add-service #[0xf0, 0xff]
  database.add-characteristic #[0xf1, 0xff] --read --write --value=#[10]
  database.add-characteristic #[0xf2, 0xff] --read --write --notify --indicate --encrypted --value=#[20]
  database.add-characteristic #[0xf3, 0xff] --read --write --authenticated --value=#[30]
  evidence := Evidence
  session := database.session --security=evidence
  // Omitting a trusted connection owner always fails closed for protected data.
  expect-equals #[1, 0x0a, 5, 0, 5] ((database.session).request #[0x0a, 5, 0])
  expect-equals #[0x0b, 10] (session.request #[0x0a, 3, 0])
  [#[0x0a, 5, 0], #[0x0c, 5, 0, 0, 0], #[0x12, 5, 0, 99],
    #[0x16, 5, 0, 0, 0, 99], #[0x12, 6, 0, 3, 0], #[0x0a, 6, 0]].do: | pdu/ByteArray |
    expect-equals #[1, pdu[0], pdu[1], 0, 5] (session.request pdu)
  expect-equals #[1, 8, 5, 0, 5] (session.request #[8, 1, 0, 8, 0, 0xf2, 0xff])
  // Find By Type Value may not emit a security error; no matching value leaks.
  expect-equals #[1, 6, 1, 0, 0x0a] (session.request #[6, 1, 0, 8, 0, 0xf2, 0xff, 20])
  expect-equals #[5, 1, 5, 0, 0xf2, 0xff] (session.request #[4, 5, 0, 5, 0])
  expect-equals #[0x0b, 0x3a, 5, 0, 0xf2, 0xff] (session.request #[0x0a, 4, 0])
  evidence.paired = true
  expect-equals #[1, 0x0a, 5, 0, 0x0f] (session.request #[0x0a, 5, 0])
  evidence.encrypted = true
  expect-equals #[0x0b, 20] (session.request #[0x0a, 5, 0])
  expect-equals #[1, 0x0a, 8, 0, 5] (session.request #[0x0a, 8, 0])
  expect-equals #[0x13] (session.request #[0x12, 6, 0, 3, 0])
  expect-equals #[0x1b, 5, 0, 20] (session.notification 5)
  expect-equals #[0x1d, 5, 0, 20] (session.indication 5)
  evidence.authenticated = true
  expect-equals #[0x0b, 30] (session.request #[0x0a, 8, 0])
  session.request #[0x16, 3, 0, 0, 0, 11]
  session.request #[0x16, 5, 0, 0, 0, 21]
  evidence.encrypted = false
  expect-equals #[1, 0x18, 5, 0, 0x0f] (session.request #[0x18, 1])
  expect-equals #[10] (database.value 3)
  expect-equals #[20] (database.value 5)
  expect-throw "GATT_INSUFFICIENT_SECURITY": session.notification 5
  expect-throw "GATT_INSUFFICIENT_SECURITY": session.indication 5
  // A rejected execute has discarded the entire prepared transaction.
  evidence.encrypted = true
  expect-equals #[0x19] (session.request #[0x18, 1])
  expect-equals #[20] (database.value 5)

handlers:
  database := server.Database
  database.add-service #[0xf0, 0xff]
  database.add-characteristic #[0xf1, 0xff] --read --write --encrypted --dynamic-read --validate-write --value=#[1]
  database.add-characteristic #[0xf1, 0xff] --read --write --encrypted --dynamic-read --validate-write --value=#[2]
  evidence := Evidence
  session := database.session --security=evidence
  expect-equals #[1, 0x0a, 3, 0, 5] (session.request #[0x0a, 3, 0]: unreachable)
  expect-equals #[1, 0x12, 3, 0, 5]
      session.request #[0x12, 3, 0, 42] (: unreachable) (: unreachable)
  evidence.paired = true
  evidence.encrypted = true
  response := session.request #[0x0a, 3, 0]: | request/server.ReadRequest |
    evidence.encrypted = false
    request.reply #[99]
  expect-equals #[1, 0x0a, 3, 0, 0x0f] response
  evidence.encrypted = true
  response = session.request #[8, 1, 0, 5, 0, 0xf1, 0xff]: | request/server.ReadRequest |
    if request.handle == 5: evidence.encrypted = false
    request.reply #[99]
  expect-equals #[1, 8, 3, 0, 0x0f] response
  evidence.encrypted = true
  response = session.request #[0x12, 3, 0, 42] (: unreachable): | request/server.WriteRequest |
    evidence.encrypted = false
    request.accept
  expect-equals #[1, 0x12, 3, 0, 0x0f] response
  expect-equals #[1] (database.value 3)
  evidence.encrypted = true
  session.request #[0x16, 3, 0, 0, 0, 42]
  session.request #[0x16, 5, 0, 0, 0, 43]
  response = session.request #[0x18, 1] (: unreachable): | request/server.WriteRequest |
    if request.handle == 5: evidence.encrypted = false
    request.accept
  expect-equals #[1, 0x18, 3, 0, 0x0f] response
  expect-equals #[1] (database.value 3)
  expect-equals #[2] (database.value 5)
