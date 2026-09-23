// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The `ble` package's peripheral API on the Toit host backend: without a
// native BLE host, Adapter falls back to the service provider, and the
// application code of a NimBLE peripheral runs unchanged.

import ble show *
import expect show *
import monitor
import ble.experimental.signaling as signaling
import .ble-fixture as fixture
import .ble-peripheral-test as peripheral
import .ble-service-gatt-test as gatt

INPUT ::= 12
ECHO ::= 14
CCCD ::= 15

main:
  with-timeout --ms=10_000:
    provider := gatt.TestProvider
    provider.install
    stopped := monitor.Latch
    finished := monitor.Latch
    ended := monitor.Latch
    done := monitor.Latch
    responder := task::
      try:
        radio := provider.radio
        fixture.initialize-replies radio
        peripheral.setup radio
        event := fixture.connection-event.copy
        event[7] = 1
        radio.received.add event
        peripheral.reply radio 0x200a #[0]
        fixture.att-sent radio (signaling.parameter-request 1) --channel=5
        radio.received.add (fixture.att-event #[0x13, 1, 2, 0, 0, 0] --channel=5)
        radio.received.add (fixture.att-event #[0x12, 9, 0, 2, 0])
        fixture.att-sent radio #[0x13]
        // A read of the notification characteristic is answered by the app.
        radio.received.add (fixture.att-event #[0x0a, ECHO, 0])
        fixture.att-sent radio #[0x0b, 0x70, 0x17]
        radio.received.add (fixture.att-event #[0x12, CCCD, 0, 1, 0])
        fixture.att-sent radio #[0x13]
        // A write reaches LocalCharacteristic.read; the app answers with a notification.
        radio.received.add (fixture.att-event #[0x12, INPUT, 0, 42])
        fixture.att-sent radio #[0x13]
        fixture.att-sent radio #[0x1b, ECHO, 0, 42]
        radio.received.add (fixture.att-event #[0x0a, ECHO, 0])
        fixture.att-sent radio #[0x0b, 42]
        stopped.get
        radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x13]
        finished.set true
      finally:
        critical-do --no-respect-deadline: ended.set true
    application := task::
      error := catch --trace: run stopped finished
      done.set error
    try:
      expect-null done.get
      ended.get
    finally:
      responder.cancel
      application.cancel
      provider.uninstall

run stopped/monitor.Latch finished/monitor.Latch -> none:
  adapter := Adapter
  expect (not adapter.adapter-metadata.identifier.is-empty)
  peripheral := adapter.peripheral
  service := peripheral.add-service (BleUuid "fff0")
  input := service.add-write-only-characteristic (BleUuid "fff1") --requires-response
  echo := service.add-notification-characteristic (BleUuid "fff2")
  echo.set-value #[0x70, 0x17]
  peripheral.deploy
  expect-throw "Already deployed": peripheral.deploy
  peripheral.start-advertise
      --interval=(Duration --us=100_000)
      --allow-connections
      Advertisement --flags=(BLE-ADVERTISE-FLAGS-GENERAL-DISCOVERY | BLE-ADVERTISE-FLAGS-BREDR-UNSUPPORTED)
  expect-equals #[42] input.read
  expect-equals INPUT input.handle
  expect-equals ECHO echo.handle
  echo.write #[42]
  // Stopping while connected keeps the connection; the peer ends it.
  peripheral.stop-advertise
  stopped.set true
  finished.get
  adapter.close
