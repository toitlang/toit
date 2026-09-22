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
  with-timeout --ms=5_000:
    provider := service.TestProvider
    provider.install
    client := clients.Client
    client.open
    received := [monitor.Latch, monitor.Latch]
    rejected := monitor.Latch
    ended := monitor.Latch
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
        radio.received.add (fixture.att-event #[8, 11, 0, 12, 0, 3, 0x28])
        fixture.att-sent radio #[9, 7, 11, 0, 6, 12, 0, 0xf1, 0xff]
        radio.received.add (fixture.att-event #[0x12, 12, 0, 77])
        fixture.att-sent radio #[1, 0x12, 12, 0, 3]
        count := radio.sent-count
        2.repeat: | index/int |
          value := index == 0 ? #[42] : #[]
          radio.received.add (fixture.att-event (#[0x52, 12, 0] + value))
          received[index].get
          expect-equals count radio.sent-count
        radio.received.add (fixture.att-event #[0x52, 12, 0, 99])
        rejected.get
        radio.received.add (fixture.att-event #[0x0a, 12, 0])
        fixture.att-sent radio #[0x0b]
        radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x13]
      finally:
        critical-do --no-respect-deadline: ended.set true
    try:
      session := client.configure
      session.add-service #[0xf0, 0xff]
      handle := session.add-characteristic #[0xf1, 0xff] --read --write-command --validate-write
      expect-equals 12 handle
      session.start #[2, 1, 6]
      values := []
      validations := 0
      session.serve
          (: | _ | unreachable)
          (: | request/clients.Request |
            validations++
            expect-equals 0x52 request.opcode
            if request.value == #[99]:
              request.reject 0x13
              rejected.set true
            else:
              request.accept)
          (: | actual/int value/ByteArray |
            expect-equals handle actual
            values.add value
            received[values.size - 1].set true)
      ended.get
      expect-equals 3 validations
      system.process-stats --gc
      expect-equals [#[42], #[]] values
    finally:
      client.close
      responder.cancel
      provider.uninstall
