// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.advertising-set
import ble.experimental.connection
import ble.experimental.central
import ble.experimental.hci
import expect show *
import .ble-fixture as fixture

main:
  with-timeout --ms=3_000:
    address := #[0xaa, 0xfb, 0x0d, 0x94, 0x81, 0x70]
    copied := connection.random-address address
    address[0] = 0
    expect-equals 0xaa copied[0]
    expect-equals 1 (advertising-set.parameters --own-address-type=1)[5]
    expect-equals 1 (connection.create-parameters address --address-type=0 --own-address-type=1)[12]
    expect-throw "INVALID_ARGUMENT": advertising-set.parameters --own-address-type=2
    expect-throw "INVALID_ARGUMENT": connection.create-parameters address --address-type=0 --own-address-type=2
    [#[0, 0, 0, 0, 0, 0x40], #[0, 0, 0, 0xff, 0xff, 0x7f],
     #[0, 0, 0, 0, 0, 0xc0], #[0xff, 0xff, 0xff, 0xff, 0xff, 0xff],
     #[1, 0, 0, 0, 0, 0], #[1, 0, 0, 0, 0, 0x80], #[1]].do: | invalid/ByteArray |
      expect-throw "INVALID_ARGUMENT": connection.random-address invalid
    expect-equals #[1, 0, 0, 0, 0, 0xc0] (connection.random-address #[1, 0, 0, 0, 0, 0xc0])
    rejected-setup copied

rejected-setup local/ByteArray:
  radio := fixture.FakeTransport
  host := central.Central (hci.Controller radio)
  responder := task::
    expect-equals (hci.command-packet 0x2005 local) radio.sent.take
    radio.received.add #[4, 14, 4, 1, 5, 0x20, 0x0c]
    // Rejection must not submit creation or leave the admission lock occupied.
    fixture.status-reply radio fixture.create-command
    radio.received.add fixture.connection-event
  try:
    error := catch:
      host.connect #[1, 2, 3, 4, 5, 6] --address-type=1 --local-random-address=local
    expect (error is hci.CommandError)
    expect-equals 0x0c error.status
    expect (not radio.closed)
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    expect-null link.local-random-address
    expect link.connected
  finally:
    responder.cancel
    host.close
    host.wait-closed
