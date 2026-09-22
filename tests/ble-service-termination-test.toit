// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import ble.experimental.service.client as clients
import ble.experimental.signaling
import .ble-fixture as fixture
import .ble-peripheral-test as peripheral
import .ble-service-gatt-test as shared

main:
  with-timeout --ms=5_000:
    provider := shared.TestProvider
    provider.install
    started := monitor.Latch
    ended := monitor.Latch
    responder := task::
      radio := provider.radio
      fixture.initialize-replies radio
      peripheral.setup radio
      event := fixture.connection-event.copy
      event[7] = 1
      radio.received.add event
      peripheral.reply radio 0x200a #[0]
      fixture.att-sent radio (signaling.parameter-request 1) --channel=5
      radio.received.add (fixture.att-event #[0x13, 1, 2, 0, 0, 0] --channel=5)
      radio.received.add (fixture.att-event #[0x0a, 5, 0])
      started.get
      radio.received.fail "HCI_QUEUE_OVERFLOW"
    client := clients.Client
    client.open
    session := client.session
    worker := task::
      try:
        session.serve
            (: | _ |
              started.set true
              sleep --ms=10_000)
            (: | _ | unreachable)
            (: | _ _ | unreachable)
      finally:
        critical-do --no-respect-deadline: ended.set true
    try:
      started.get
      with-timeout --ms=200: ended.get
      expect worker.is-canceled
      expect-equals "HCI_QUEUE_OVERFLOW" session.termination-reason
      expect session.is-closed
      expect-throw "GATT_REQUESTS_CLOSED": session.value 3
      expect provider.radio.closed
    finally:
      worker.cancel
      responder.cancel
      session.close
      client.close
      provider.uninstall
