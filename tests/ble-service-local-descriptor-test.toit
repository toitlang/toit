// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import system
import ble.experimental.signaling as signaling
import ble.experimental.service.client as clients
import .ble-service-gatt-test as service
import .ble-fixture as fixture
import .ble-peripheral-test as peripheral

main:
  vendor-descriptor
  writable-description

vendor-descriptor:
  with-timeout --ms=5_000:
    provider := service.TestProvider
    provider.install
    client := clients.Client
    client.open
    observed := [monitor.Latch, monitor.Latch]
    ended := monitor.Latch
    expected := ByteArray 44: it
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
        exchange radio #[4, 13, 0, 14, 0] #[5, 1, 13, 0, 0xf2, 0xff, 14, 0, 1, 0x29]
        exchange radio #[0x12, 14, 0, 99] #[1, 0x12, 14, 0, 3]
        exchange radio #[0x0a, 14, 0] #[0x0b, 65]
        [0, 18, 36].do: | offset/int |
          bytes := expected[offset..min 44 (offset + 18)]
          exchange radio (#[0x16, 13, 0, offset, 0] + bytes) (#[0x17, 13, 0, offset, 0] + bytes)
        exchange radio #[0x18, 1] #[0x19]
        observed[0].get
        exchange radio #[0x0a, 13, 0] (#[0x0b] + expected[..22])
        exchange radio #[0x0c, 13, 0, 22, 0] (#[0x0d] + expected[22..])
        exchange radio #[0x12, 13, 0] #[0x13]
        observed[1].get
        exchange radio #[0x0a, 13, 0] #[0x0b]
        radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x13]
      finally:
        critical-do --no-respect-deadline: ended.set true
    try:
      session := client.configure --value-limit=512
      session.add-service #[0xf0, 0xff]
      value := session.add-characteristic #[0xf1, 0xff] --read
      descriptor := session.add-descriptor value #[0xf2, 0xff] --write
      expect-equals 13 descriptor
      expect-equals 14 (session.add-descriptor value #[1, 0x29] --value=#[65])
      expect-throw "GATT_DUPLICATE_DESCRIPTOR":
        session.add-descriptor value #[1, 0x29] --value=#[66]
      expect-equals 15 (session.add-descriptor value #[0xf3, 0xff] --value=#[67])
      session.start #[2, 1, 6]
      retained := []
      session.serve
          (: | _ | unreachable)
          (: | _ | unreachable)
          (: | handle/int bytes/ByteArray |
            expect-equals descriptor handle
            expect-equals (retained.is-empty ? expected : #[]) bytes
            retained.add bytes
            system.process-stats --gc
            observed[retained.size - 1].set true)
      ended.get
      expect-equals [expected, #[]] retained
    finally:
      client.close
      responder.cancel
      provider.uninstall

writable-description:
  with-timeout --ms=5_000:
    provider := service.TestProvider
    provider.install
    client := clients.Client
    client.open
    observed := [monitor.Latch, monitor.Latch]
    ended := monitor.Latch
    expected := ByteArray 44 --initial=65
    expected.replace 17 #[0xe2, 0x82, 0xac]
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
        exchange radio #[8, 11, 0, 11, 0, 3, 0x28] #[9, 7, 11, 0, 0x82, 12, 0, 0xf1, 0xff]
        exchange radio #[4, 13, 0, 14, 0] #[5, 1, 13, 0, 0, 0x29, 14, 0, 1, 0x29]
        exchange radio #[0x0a, 13, 0] #[0x0b, 2, 0]
        exchange radio #[0x12, 13, 0, 0, 0] #[1, 0x12, 13, 0, 3]
        exchange radio #[0x12, 14, 0, 0xc0, 0xaf] #[1, 0x12, 14, 0, 0x13]
        [0, 18, 36].do: | offset/int |
          bytes := expected[offset..min 44 (offset + 18)]
          exchange radio (#[0x16, 14, 0, offset, 0] + bytes) (#[0x17, 14, 0, offset, 0] + bytes)
        exchange radio #[0x18, 1] #[0x19]
        observed[0].get
        exchange radio #[0x0a, 14, 0] (#[0x0b] + expected[..22])
        exchange radio #[0x0c, 14, 0, 22, 0] (#[0x0d] + expected[22..])
        exchange radio #[0x12, 14, 0] #[0x13]
        observed[1].get
        radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x13]
      finally:
        critical-do --no-respect-deadline: ended.set true
    try:
      session := client.configure --value-limit=512
      session.add-service #[0xf0, 0xff]
      value := session.add-characteristic #[0xf1, 0xff] --read
      expect-throw "INVALID_ARGUMENT":
        session.add-descriptor value #[1, 0x29] --write --value=#[0xff]
      description := session.add-descriptor value #[1, 0x29] --write --value=#[65]
      expect-equals 14 description
      expect-throw "GATT_INVALID_VALUE_HANDLE": session.set-value 13 #[0, 0]
      expect-throw "INVALID_ARGUMENT": session.set-value description #[0xff]
      session.start #[2, 1, 6]
      retained := []
      session.serve
          (: | _ | unreachable)
          (: | _ | unreachable)
          (: | handle/int bytes/ByteArray |
            expect-equals description handle
            expect-equals (retained.is-empty ? expected : #[]) bytes
            retained.add bytes
            system.process-stats --gc
            observed[retained.size - 1].set true)
      ended.get
      expect-equals [expected, #[]] retained
    finally:
      client.close
      responder.cancel
      provider.uninstall

exchange radio/fixture.FakeTransport request/ByteArray response/ByteArray:
  radio.received.add (fixture.att-event request)
  fixture.att-sent radio response
