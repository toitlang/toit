// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import io
import .ble-hci-test as fixture

// Keeps credit commands separate from the existing ATT response assertions.
// Every returned credit must match a packet received on the same live handle.
class Radio extends fixture.FakeTransport:
  pending_/Map ::= {:}
  received-acl/int := 0
  returned/int := 0

  receive -> ByteArray:
    packet := super
    if packet[0] == 2:
      handle := (io.LITTLE-ENDIAN.uint16 packet 1) & 0xfff
      pending_.update handle --init=0: it + 1
      received-acl++
    return packet

  send packet/ByteArray -> none:
    if packet.size >= 4 and packet[0] == 1 and packet[1] == 0x35 and packet[2] == 0x0c:
      expect (not closed)
      expect-equals 9 packet.size
      expect-equals 5 packet[3]
      expect-equals 1 packet[4]
      expect-equals 1 (io.LITTLE-ENDIAN.uint16 packet 7)
      handle := io.LITTLE-ENDIAN.uint16 packet 5
      pending_.update handle: | count/int |
        expect (count > 0)
        count - 1
      returned++
      return
    super packet

  check -> none:
    expect (returned > 0)
    expect-equals received-acl returned
    pending_.values.do: expect-equals 0 it

initialize radio/fixture.FakeTransport enabled/bool --acl-length/int=251:
  fixture.initialize-replies radio --receive-flow=enabled --acl-length=acl-length
  if enabled:
    fixture.reply radio #[1, 0x33, 0x0c, 7, 0, 4, 0, 4, 0, 0, 0] #[]
    fixture.reply radio #[1, 0x31, 0x0c, 1, 1] #[]

check radio/fixture.FakeTransport:
  if radio is Radio: (radio as Radio).check
