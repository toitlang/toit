// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.linux-management
import expect show *
import io
import .ble-hci-test as fixture

main:
  with-timeout --ms=2_000:
    radio := fixture.FakeTransport
    client := linux-management.Client radio 7
    bytes := ByteArray 280
    bytes.replace 0 #[1, 2, 3, 4, 5, 6]
    io.LITTLE-ENDIAN.put-uint32 bytes 9 0x2001
    io.LITTLE-ENDIAN.put-uint32 bytes 13 0x2000
    // Ignore another adapter's completion and unrelated asynchronous events.
    radio.received.add #[1, 0, 8, 0, 3, 0, 4, 0, 3]
    radio.received.add #[6, 0, 7, 0, 4, 0, 1, 0, 0, 0]
    radio.received.add (#[1, 0, 7, 0, 0x1b, 1, 4, 0, 0] + bytes)
    info := client.info
    expect-equals #[4, 0, 7, 0, 0, 0] radio.sent.take
    expect-equals #[1, 2, 3, 4, 5, 6] info.address
    expect-equals 0x2001 info.supported-settings
    expect info.privacy
    expect (not info.powered)
    copy := info.address
    copy[0] = 99
    expect-equals 1 info.address[0]
    radio.received.add #[1, 0, 7, 0, 7, 0, 5, 0, 0, 1, 0, 0, 0]
    expect-equals 1 (client.set-powered true)
    expect-equals #[5, 0, 7, 0, 1, 0, 1] radio.sent.take
    irk := ByteArray 16: it
    radio.received.add #[1, 0, 7, 0, 7, 0, 0x2f, 0, 0, 0, 0x20, 0, 0]
    expect-equals 0x2000 (client.set-privacy 1 irk)
    expect-equals (#[0x2f, 0, 7, 0, 17, 0, 1] + irk) radio.sent.take
    expect-throw "INVALID_ARGUMENT": client.set-privacy 3 irk
    expect-throw "INVALID_ARGUMENT": client.set-privacy 1 #[]
    radio.received.add #[2, 0, 7, 0, 3, 0, 5, 0, 10]
    expect-throw "MGMT_STATUS_10": client.set-powered false
    expect radio.closed

    [#[], #[1, 0, 7, 0, 3, 0], #[1, 0, 7, 0, 0, 0]].do: | malformed/ByteArray |
      other := fixture.FakeTransport
      management := linux-management.Client other 7
      other.received.add malformed
      expect-throw "MGMT_INVALID_RESPONSE": management.info
      expect other.closed

    pending := fixture.FakeTransport
    management := linux-management.Client pending 7
    error := catch:
      with-timeout --ms=10: management.info
    expect-equals "DEADLINE_EXCEEDED" error
    expect pending.closed
