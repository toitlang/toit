// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.attribute-server as attributes
import expect show *
import ble.experimental.att
import ble.experimental.central
import ble.experimental.gatt
import ble.experimental.hci
import .ble-hci-test as fixture

main:
  with-timeout --ms=5_000: scoped-indications
  database := attributes.Database.with-defaults
  session := database.session
  other := database.session
  expect-equals #[9, 7, 7, 0, 0x20, 8, 0, 5, 0x2a]
      session.request #[8, 6, 0, 9, 0, 3, 0x28]
  expect-equals #[5, 1, 9, 0, 2, 0x29] (session.request #[4, 9, 0, 9, 0])
  expect-equals #[1, 0x0a, 8, 0, 2] (session.request #[0x0a, 8, 0])
  expect-equals #[1, 0x12, 8, 0, 3] (session.request #[0x12, 8, 0, 1, 0, 0xff, 0xff])
  expect-throw "GATT_INVALID_VALUE_HANDLE": database.set-value 8 #[0]
  expect-equals null (session.indication 8)
  expect-equals #[1, 0x12, 9, 0, 0x13] (session.request #[0x12, 9, 0, 1, 0])
  expect-equals #[0x13] (session.request #[0x12, 9, 0, 2, 0])
  session.writes-do: unreachable
  expect-equals #[0x0b, 2, 0] (session.request #[0x0a, 9, 0])
  expect-equals #[0x1d, 8, 0, 1, 0, 0xff, 0xff] (session.indication 8)
  expect-equals null (other.indication 8)
  // Prepared internal CCCD writes are handled without application callbacks too.
  session.request #[0x16, 9, 0, 0, 0, 0, 0]
  expect-equals #[0x19] (session.request #[0x18, 1])
  session.writes-do: unreachable
  expect-equals null (session.indication 8)
  expect-throw "GATT_DATABASE_SEALED": database.add-service #[0xf0, 0xff]
  expect-throw "GATT_DATABASE_SEALED": database.add-characteristic #[0xf1, 0xff] --read
  session.close
  other.close
  // Firmware-upgradable, unbonded devices start each connection unsubscribed.
  expect-equals null (database.session.indication 8)
  immutable := attributes.Database.with-defaults --immutable-layout
  expect-equals #[1, 8, 6, 0, 0x0a] (immutable.session.request #[8, 6, 0, 0xff, 0xff, 3, 0x28])

scoped-indications:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport)
  client/att.Client? := null
  responder := task::
    fixture.status-reply transport fixture.create-command
    transport.received.add fixture.connection-event
    fixture.gatt-reply transport #[4, 9, 0, 9, 0] #[5, 1, 9, 0, 2, 0x29]
    fixture.att-sent transport #[0x12, 9, 0, 2, 0]
    transport.received.add (fixture.att-event #[0x1d, 8, 0, 1, 0, 0xff, 0xff])
    fixture.att-sent transport #[0x1e]
    transport.received.add (fixture.att-event #[0x13])
    fixture.gatt-reply transport #[0x12, 9, 0, 0, 0] #[0x13]
  try:
    client = att.Client host (host.connect #[1, 2, 3, 4, 5, 6] --address-type=1)
    characteristic := gatt.Characteristic 7 8 0x20 #[5, 0x2a]
    characteristic.end = 9
    expect-throw "GATT_NOT_NOTIFIABLE": gatt.with-notifications client characteristic: unreachable
    answer := gatt.with-indications client characteristic: | stream/att.Subscription |
      expect-equals #[1, 0, 0xff, 0xff] stream.receive
      42
    expect-equals 42 answer
  finally:
    responder.cancel
    if client: client.close
    host.close
    host.wait-closed
