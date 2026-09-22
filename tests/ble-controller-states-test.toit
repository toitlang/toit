// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.controller-states as states
import ble.experimental.hci
import expect show *
import .ble-fixture as fixture

main:
  with-timeout --ms=5_000:
    masks
    query 0 8
    query 0 7
    query 0 9
    query 1 0

masks:
  expect-equals 35 states.CONNECTABLE-ADVERTISING-WITH-CENTRAL
  expect-equals 41 states.INITIATING-WITH-PERIPHERAL
  42.repeat: | bit/int |
    bytes := ByteArray 8
    bytes[bit >> 3] = 1 << (bit & 7)
    snapshot := states.States bytes
    bytes.fill 0
    snapshot.bytes.fill 0
    42.repeat: | other/int |
      expect-equals (bit == other) (snapshot.supports other)
  empty := states.States (ByteArray 8)
  42.repeat: expect (not (empty.supports it))
  reserved := states.States #[0, 0, 0, 0, 0, 0xfc, 0xff, 0xff]
  42.repeat: expect (not (reserved.supports it))
  expect-equals #[0, 0, 0, 0, 0, 0xfc, 0xff, 0xff] reserved.bytes
  expect-throw "INVALID_ARGUMENT": reserved.supports -1
  expect-throw "INVALID_ARGUMENT": reserved.supports 42
  expect-throw "HCI_MALFORMED_RESPONSE": states.States (ByteArray 7)

query status/int length/int:
  transport := fixture.FakeTransport
  controller := hci.Controller transport
  responder := task::
    expect-equals #[1, 0x1c, 0x20, 0] transport.sent.take
    response := ByteArray (7 + length)
    response.replace 0 #[4, 14, 4 + length, 1, 0x1c, 0x20, status]
    if length == 8: response.replace 7 #[0, 0, 0, 0, 8, 2, 0, 0]
    transport.received.add response
  try:
    result/states.States? := null
    error := catch: result = states.read controller
    if status != 0:
      expect (error is hci.CommandError)
      expect-equals 0x201c (error as hci.CommandError).opcode
      expect-equals status (error as hci.CommandError).status
    else if length != 8:
      expect-equals "HCI_MALFORMED_RESPONSE" error
    else:
      expect-equals null error
      expect (result.supports states.CONNECTABLE-ADVERTISING-WITH-CENTRAL)
      expect (result.supports states.INITIATING-WITH-PERIPHERAL)
    expect (not transport.closed)
  finally:
    responder.cancel
    controller.close
    controller.wait-closed
