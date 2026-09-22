// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.service.client as clients
import ble.experimental.signaling
import expect show *
import monitor
import .ble-hci-test as fixture
import .ble-peripheral-test as peripheral
import .ble-service-gatt-test as shared

main:
  with-timeout --ms=15_000:
    provider := shared.TestProvider
    provider.install
    client := clients.Client
    client.open
    session := client.configure --handler-timeout=(Duration --s=7)
    session.add-service #[0xf0, 0xff]
    first := session.add-characteristic #[0xf1, 0xff] --write --validate-write --value=#[1]
    second := session.add-characteristic #[0xf2, 0xff] --write --validate-write --value=#[2]
    started := monitor.Latch
    ended := monitor.Latch
    closed := monitor.Latch
    entered := 0
    completed := 0
    unwound := 0
    saved/clients.Request? := null
    radio := provider.radio
    responder := task::
      fixture.initialize-replies radio
      peripheral.setup radio
      event := fixture.connection-event.copy
      event[7] = 1
      radio.received.add event
      peripheral.reply radio 0x200a #[0]
      fixture.att-sent radio (signaling.parameter-request 1) --channel=5
      radio.received.add (fixture.att-event #[0x13, 1, 2, 0, 0, 0] --channel=5)
      [first, second].do: | handle/int |
        radio.received.add (fixture.att-event #[0x16, handle, 0, 0, 0, 42])
        fixture.att-sent radio #[0x17, handle, 0, 0, 0, 42]
      radio.received.add (fixture.att-event #[0x18, 1])
      while not radio.closed: sleep --ms=1
      closed.set true
    session.start #[2, 1, 6]
    worker := task::
      try:
        session.serve
            (: | request/clients.Request | unreachable)
            (: | request/clients.Request |
              entered++
              saved = request
              if entered == 2: started.set true
              try:
                sleep --ms=6_000
                request.accept
                completed++
              finally:
                unwound++)
            (: | handle/int value/ByteArray | unreachable)
      finally:
        critical-do --no-respect-deadline: ended.set true
    try:
      started.get
      // Even the first successful remote validation cannot commit early.
      expect-equals #[1] (session.value first)
      expect-equals #[2] (session.value second)
      ended.get
      closed.get
      expect worker.is-canceled
      expect-equals 2 entered
      expect-equals 1 completed
      expect-equals 2 unwound
      expect-throw "GATT_REQUEST_EXPIRED": saved.accept
      // Complete cleanup must permit another builder without opening radio.
      replacement := client.configure
      replacement.close
    finally:
      worker.cancel
      responder.cancel
      session.close
      client.close
      provider.uninstall
