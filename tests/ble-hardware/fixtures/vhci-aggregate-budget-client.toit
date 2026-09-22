// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.central
import ble.experimental.esp32
import ble.experimental.hci
import ble.experimental.signaling
import encoding.hex

main:
  with-timeout --ms=40_000:
    controller := hci.Controller (esp32.Esp32Transport)
    host/central.Central? := null
    try:
      info := hci.initialize controller
      host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
      address := (hex.decode "f412fac150fe").reverse
      link := host.connect address --address-type=0
      // This paired fixture deliberately uses its printed fixed layout, not
      // the normal GATT client, whose shorter request timeout would mask the
      // server aggregate limit being tested.
      [12, 14].do: | handle/int |
        host.send link 4 #[0x16, handle, 0, 0, 0, 42]
        if (receive-att host link) != #[0x17, handle, 0, 0, 0, 42]: throw "PREPARE_ECHO_FAILED"
      host.send link 4 #[0x18, 1]
      error := catch: with-timeout --ms=16_000: receive-att host link
      if error != "HCI_LINK_DISCONNECTED": throw "EXPECTED_AGGREGATE_DISCONNECT"
      print "AGGREGATE_CLIENT DISCONNECTED pending-execute=true"
      link = host.connect address --address-type=0
      host.send link 4 #[0x0a, 12, 0]
      if (receive-att host link) != #[0x0b, 44]: throw "REPLACEMENT_READ_FAILED"
      host.disconnect link
      print "AGGREGATE_CLIENT COMPLETE replacement-value=44"
    finally:
      if host:
        host.close
        host.wait-closed
      else:
        controller.close
        controller.wait-closed

receive-att host/central.Central link/central.Link -> ByteArray:
  while true:
    packet := link.receive
    if packet.channel == 4: return packet.payload
    if packet.channel != 5: throw "UNEXPECTED_CHANNEL"
    host.handle-signaling link packet.payload
