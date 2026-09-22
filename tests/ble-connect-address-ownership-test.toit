// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.central
import ble.experimental.extended-central as extended
import ble.experimental.hci
import expect show *
import system
import .ble-connect-isolation-test as isolation
import .ble-fixture as fixture
import .ble-multilink-test as links

main:
  with-timeout --ms=5_000:
    [false, true].do: | extended-mode/bool |
      [false, true].do: | changed-peer/bool |
        address-ownership extended-mode changed-peer

address-ownership extended-mode/bool changed-peer/bool:
  radio := fixture.FakeTransport
  controller := hci.Controller radio
  host := extended-mode ? (extended.Central controller) : (central.Central controller)
  address := links.address 1
  responder := task::
    expected := hci.command-packet host.connection-opcode
        host.encode-connection (links.address 1) --address-type=1 --own-address-type=0
    expect-equals expected radio.sent.take
    // Mutate while Create Connection is awaiting its status. Neither accepting
    // the original peer nor rejecting another peer may use this borrowed array.
    address.replace 0 (links.address 2)
    system.process-stats --gc
    radio.received.add #[4, 15, 4, 0, 1, host.connection-opcode & 0xff, 0x20]
    radio.received.add
        isolation.completed-connection (changed-peer ? 2 : 1) 0x234 --extended-mode=extended-mode
    if not changed-peer:
      links.incoming radio 0x234 #[1, 0, 4, 0, 42] --start
  try:
    if changed-peer:
      expect-throw "HCI_UNEXPECTED_PEER": host.connect address --address-type=1
      host.wait-closed
      expect radio.closed
    else:
      link := host.connect address --address-type=1
      system.process-stats --gc
      expect-equals (links.address 1) link.info.address
      expect-equals #[42] link.receive.payload
      expect (link.connected and not radio.closed)
    expect-equals (links.address 2) address
  finally:
    responder.cancel
    host.close
    host.wait-closed
