// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.att
import ble.experimental.central
import ble.experimental.gatt
import ble.experimental.hci
import encoding.hex
import expect show *
import io
import system
import ..ble-fixture as fixture

main:
  with-timeout --ms=25_000:
    transport := fixture.FakeTransport
    host := central.Central (hci.Controller transport)
    client/att.Client? := null
    bridge := task::
      fixture.status-reply transport fixture.create-command
      transport.received.add fixture.connection-event
      input := io.stdin
      while true:
        packet := transport.sent.take
        length := packet.size - 9
        expect (0 < length <= 23)
        expect-equals #[2, 0x34, 2, length + 4, 0, length, 0, 4, 0] packet[..9]
        print "PDU $(hex.encode packet[9..])"
        transport.received.add #[4, 0x13, 5, 1, 0x34, 2, 1, 0]
        line := input.read-line
        if not line: throw "ATT_PEER_EXITED"
        response := hex.decode line
        expect (0 < response.size <= 23)
        transport.received.add (fixture.att-event response)
    try:
      link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
      client = att.Client host link
      expect-equals 23 client.exchange-mtu
      services := gatt.services client
      expect-equals 1 services.size
      expect-equals #[0xf0, 0xff] services[0].uuid
      characteristics := gatt.characteristics client services[0]
      expect-equals 1 characteristics.size
      expect-equals #[0xf1, 0xff] characteristics[0].uuid
      handle := characteristics[0].handle
      expect-equals #[7] (client.read handle)
      [0, 1, 18, 19, 20, 21, 22, 23, 44, 128, 129, 512].do: | length/int |
        bytes := ByteArray length: (it * 17 + length) % 251
        client.write-long handle bytes
        system.process-stats --gc
        expect-equals bytes (client.read-long handle)
      // An independent peer's ATT error must preserve subsequent operation.
      error := catch: client.read 0xffff
      expect (error is att.AttributeError and error.code == 1)
      client.write handle #[42]
      expect-equals #[42] (client.read handle)
    finally:
      bridge.cancel
      if client: client.close
      host.close
      host.wait-closed
    print "ATT_CLIENT COMPLETE values=12 recovered=true"
