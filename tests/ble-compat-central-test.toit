// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The `ble` package's central API on the Toit host backend: scan-less
// connect by identifier, discovery, read, write, subscribe and
// wait-for-notification against an emulated GATT server.

import ble show *
import expect show *
import monitor
import ble.experimental.attribute-server as attributes
import .ble-fixture as fixture
import .ble-mtu-server-test as wire
import .ble-service-central-test as service

main:
  with-timeout --ms=10_000:
    provider := service.Provider
    provider.install
    provider.radio.auto-disconnect = true
    database := attributes.Database.with-defaults
    database.add-service #[0xf0, 0xff]
    database.add-characteristic #[0xf1, 0xff] --read --write --notify --value=#[7]
    emulator := database.session
    responder := task::
      catch --unwind=(: it != "FAKE_CLOSED"):
        radio := provider.radio
        fixture.initialize-replies radio
        fixture.status-reply radio fixture.create-command
        radio.received.add fixture.connection-event
        while true:
          packet := radio.sent.take
          expect-equals 2 packet[0]
          radio.received.add #[4, 0x13, 5, 1, 0x34, 2, 1, 0]
          request := packet[9..]
          response := emulator.request request
          if response:
            wire.incoming radio response
            emulator.response-sent
          // Subscribing brings one notification of the value that follows.
          if request[0] == 0x12 and request.size == 5 and request[3] == 1 and request[4] == 0:
            handle := request[1] | (request[2] << 8)
            wire.incoming radio #[0x1b, handle - 1, 0, 9]
    done := monitor.Latch
    application := task::
      error := catch --trace: run
      done.set error
    try:
      expect-null done.get
    finally:
      responder.cancel
      application.cancel
      provider.uninstall

run -> none:
  adapter := Adapter
  central := adapter.central
  expect-equals [] central.bonded-peers
  identifier := #[1, 1, 2, 3, 4, 5, 6]
  device := central.connect identifier
  expect-equals identifier device.identifier
  expect (device.mtu >= 23)
  services := device.discover-services [BleUuid "fff0"]
  expect-equals 1 services.size
  service := services[0]
  expect-equals (BleUuid "fff0") service.uuid
  expect-equals 1 device.discovered-services.size
  characteristics := service.discover-characteristics [BleUuid "fff1"]
  expect-equals 1 characteristics.size
  characteristic := characteristics[0]
  expect (characteristic.properties & CHARACTERISTIC-PROPERTY-NOTIFY != 0)
  expect-equals #[7] characteristic.read
  characteristic.write #[8]
  expect-equals #[8] characteristic.read
  descriptors := characteristic.discover-descriptors
  expect (descriptors.any: it.uuid == (BleUuid "2902"))
  expect-throw "Characteristic is not subscribed": characteristic.wait-for-notification
  characteristic.subscribe
  expect-equals #[9] characteristic.wait-for-notification
  characteristic.unsubscribe
  device.close
  expect device.is-closed
  adapter.close
