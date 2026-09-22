// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import ble.experimental.attribute-server as attributes
import .ble-attribute-security-test as security

main:
  database := attributes.Database --value-limit=20
  database.add-service #[0xf0, 0xff]
  database.add-characteristic #[0xf1, 0xff] --read --write-command --value=#[7]
  database.add-characteristic #[0xf2, 0xff] --read --write --value=#[8]
  database.add-characteristic #[0xf3, 0xff] --read --write-command --authenticated --validate-write --value=#[9]
  evidence := security.Evidence
  session := database.session --security=evidence
  try:
    // Invalid, oversized, signed and unsupported commands must stay silent.
    [#[0x52], #[0x52, 3], #[0x52, 0, 0], #[0x52, 99, 0],
      #[0x52, 5, 0, 99], (#[0x52, 3, 0] + (ByteArray 21)),
      #[0xd2, 3, 0, 99], #[0x52, 7, 0, 99]].do: | pdu/ByteArray |
      expect-null (session.request pdu)
      session.writes-do: | _ _ | unreachable
    expect-equals #[7] (database.value 3)
    expect-equals #[8] (database.value 5)
    expect-equals #[9] (database.value 7)
    expect-equals #[1, 0x16, 3, 0, 3] (session.request #[0x16, 3, 0, 0, 0, 99])
    evidence.paired = true
    evidence.encrypted = true
    // Authentication is independently required.
    expect-null (session.request #[0x52, 7, 0, 99])
    expect-equals #[9] (database.value 7)
    evidence.authenticated = true
    calls := 0
    expect-null
        session.request #[0x52, 7, 0, 99]
            (: | _ | unreachable)
            (: | request/attributes.WriteRequest |
              calls++
              request.accept
              evidence.encrypted = false)
    expect-equals 1 calls
    expect-equals #[9] (database.value 7)
    session.writes-do: | _ _ | unreachable
    evidence.encrypted = true
    expect-null
        session.request #[0x52, 7, 0, 42]
            (: | _ | unreachable)
            (: | request/attributes.WriteRequest | request.accept)
    expect-equals #[42] (database.value 7)
    count := 0
    session.writes-do: | handle/int value/ByteArray |
      count++
      expect-equals 7 handle
      expect-equals #[42] value
      value.fill 0
    expect-equals 1 count
    session.writes-do: | _ _ | unreachable
    expect-equals #[42] (database.value 7)
  finally:
    session.close
