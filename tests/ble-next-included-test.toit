// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Secondary and included services: the database rules, and a server defined
// through the application API whose include a central reads.

import expect show *
import monitor
import ble.experimental.attribute-server as attributes
import ble.v2 as ble
import .ble-fixture as fixture
import .ble-next-peripheral-test as peripheral

main:
  rules
  with-timeout --ms=10_000: through-api

rules:
  database := attributes.Database
  first := database.add-service #[0x0f, 0x18] --secondary
  // Includes belong to a service, directly after its declaration.
  expect-throw "INVALID_ARGUMENT": database.include-service first
  database.add-characteristic #[0x19, 0x2a] --read --value=#[1]
  second := database.add-service #[0xf0, 0xff]
  expect-throw "INVALID_ARGUMENT": database.include-service second
  expect-throw "INVALID_ARGUMENT": database.include-service first + 1
  expect-throw "INVALID_ARGUMENT": database.include-service 99
  include := database.include-service first
  expect-equals #[1, 0, 3, 0, 0x0f, 0x18] (database.attributes_[include - 1] as any).value
  database.add-characteristic #[0xf1, 0xff] --read --value=#[2]
  expect-throw "INVALID_ARGUMENT": database.include-service first

through-api:
  expect-throw "INVALID_ARGUMENT":
    server := ble.GattServer
    later := server.add-service (ble.BleUuid "fff0")
    (server.add-service (ble.BleUuid "fff1")).include later
    later.include later
  // A later service cannot be included by an earlier one.
  server := ble.GattServer
  battery := server.add-service (ble.BleUuid "180f") --secondary
  battery.add-characteristic (ble.BleUuid "2a19") --read --value=#[90]
  main-service := server.add-service (ble.BleUuid "fff0")
  expect-throw "INVALID_ARGUMENT": battery.include main-service
  main-service.include battery
  expect-throw "INVALID_ARGUMENT": main-service.include battery
  expect-equals [battery] main-service.includes

  provider := peripheral.Provider
  provider.install
  ended := monitor.Latch
  responder := task::
    try:
      radio := provider.radios.receive
      fixture.initialize-replies radio
      peripheral.accept radio
      // Defaults end at 13: the battery service is 14 to 16, the main
      // service starts at 17 with its include at 18.
      radio.received.add (fixture.att-event #[0x08, 17, 0, 0xff, 0xff, 0x02, 0x28])
      fixture.att-sent radio #[0x09, 8, 18, 0, 14, 0, 16, 0, 0x0f, 0x18]
      radio.received.add (fixture.att-event #[0x10, 1, 0, 0xff, 0xff, 0x01, 0x28])
      fixture.att-sent radio #[0x11, 6, 14, 0, 16, 0, 0x0f, 0x18]
      radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x13]
    finally:
      critical-do --no-respect-deadline: ended.set true
  adapter := ble.Adapter
  try:
    role := adapter.peripheral server --advertisement=peripheral.ADVERTISEMENT
    connection := role.accept
    expect-equals ble.DisconnectReason.REMOTE-USER connection.wait-closed.code
    connection.close
    role.close
    ended.get
  finally:
    adapter.close
    responder.cancel
    provider.uninstall
