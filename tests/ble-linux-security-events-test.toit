// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import io
import .ble-hardware.linux-security-events as observer

main:
  peer := observer.address "C8:3A:F2:23:30:01"
  expect-equals #[1, 0x30, 0x23, 0xf2, 0x3a, 0xc8] peer
  expect-throw "INVALID_ARGUMENT": observer.address "0011"
  [0x000c, 0x000d, 0x0011].do: | event/int |
    256.repeat: | detail/int |
      bytes := packet event (peer + #[2, detail])
      expect-equals [event, detail] (observer.decode bytes 1 peer 2)
      expect-null (observer.decode bytes 0 peer 2)
      expect-null (observer.decode bytes 1 peer 1)
      bytes[6] ^= 1
      expect-null (observer.decode bytes 1 peer 2)
  // Connected may include opaque EIR bytes; only flags escape the decoder.
  [#[], #[3, 9, 65, 66], ByteArray 255 --initial=0xa5].do: | eir/ByteArray |
    payload := peer + #[2, 8, 0, 0, 0, eir.size, 0] + eir
    bytes := packet 0x000b payload
    decoded := observer.decode bytes 1 peer 2
    bytes.fill 0
    expect-equals [0x000b, 8] decoded
  // Ignore all other event kinds, including key/identity notifications. They
  // cannot be mistaken for a selected event even when their payload matches.
  [0x0001, 0x0009, 0x000a, 0x0012, 0x0018, 0x001a, 0xffff].do: | event/int |
    expect-null (observer.decode (packet event (peer + #[2] + (ByteArray 32 --initial=0xa5))) 1 peer 2)
  [0x000b, 0x000c, 0x000d, 0x0011].do: | event/int |
    body := peer + #[2, 1]
    if event == 0x000b: body += #[0, 0, 0, 0, 0]
    bytes := packet event body
    bytes.size.repeat: | size/int |
      expect-throw "MGMT_OBSERVER_MALFORMED": observer.decode bytes[..size] 1 peer 2
    expect-throw "MGMT_OBSERVER_MALFORMED": observer.decode (bytes + #[0]) 1 peer 2
    // Repair the outer length so selected-event framing is tested separately.
    expect-throw "MGMT_OBSERVER_MALFORMED": observer.decode (packet event body[..body.size - 1]) 1 peer 2
    expect-throw "MGMT_OBSERVER_MALFORMED": observer.decode (packet event (body + #[0])) 1 peer 2

packet event/int payload/ByteArray -> ByteArray:
  header := ByteArray 6
  io.LITTLE-ENDIAN.put-uint16 header 0 event
  io.LITTLE-ENDIAN.put-uint16 header 2 1
  io.LITTLE-ENDIAN.put-uint16 header 4 payload.size
  return header + payload
