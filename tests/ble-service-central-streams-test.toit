// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import system
import ble.experimental.service.client as clients
import .ble-fixture as fixture
import .ble-service-central-test as service

main:
  with-timeout --ms=10_000:
    provider := service.Provider
    provider.install
    client := clients.Client
    client.open
    responder := task::
      radio := provider.radio
      fixture.initialize-replies radio
      fixture.status-reply radio fixture.create-command
      radio.received.add fixture.connection-event
      8.repeat: | index/int |
        fixture.gatt-reply radio #[0x12, 4 + 2 * index, 0, 1, 0] #[0x13]
      // Four values per stream fill the shared budget, even though each stream
      // individually permits 32. Yield so HCI ingress is not the limiting queue.
      4.repeat: | value/int |
        8.repeat: | index/int |
          radio.received.add (fixture.att-event #[0x1b, 3 + 2 * index, 0, index, value])
          sleep --ms=1
      radio.received.add (fixture.att-event #[0x1b, 3, 0, 99])
      sleep --ms=1
      fixture.gatt-reply radio #[0x0a, 3, 0] #[0x0b, 42]
      8.repeat: | index/int |
        fixture.gatt-reply radio #[0x12, 18 - 2 * index, 0, 0, 0] #[0x13]
      // Reuse the same attribute after all original scopes close.
      fixture.gatt-reply radio #[0x12, 4, 0, 1, 0] #[0x13]
      radio.received.add (fixture.att-event #[0x1b, 3, 0, 77])
      fixture.gatt-reply radio #[0x12, 4, 0, 0, 0] #[0x13]
      fixture.status-reply radio #[1, 6, 4, 3, 0x34, 2, 0x13]
      radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x16]
    try:
      client.with-connection #[1, 2, 3, 4, 5, 6] --address-type=1: | connection/clients.Connection |
        streams := []
        nested connection streams
        connection.subscribe 3 --cccd=4: | replacement/clients.Subscription |
          // An escaped old stream must not resolve to the replacement token.
          expect-throw "ATT_SUBSCRIPTION_CLOSED": streams[0].receive
          expect-equals #[77] replacement.receive
      expect provider.radio.closed
    finally:
      responder.cancel
      client.close
      provider.uninstall

nested connection/clients.Connection streams/List:
  index := streams.size
  if index == 8:
    expect-throw "ATT_SUBSCRIPTION_LIMIT":
      connection.subscribe 19 --cccd=20: unreachable
    expect-equals #[42] (connection.read 3)
    expect-throw "ATT_NOTIFICATION_OVERFLOW": streams[0].receive
    retained := []
    7.repeat: | offset/int |
      stream/clients.Subscription := streams[offset + 1]
      4.repeat: | value/int |
        actual := stream.receive
        expect-equals #[offset + 1, value] actual
        retained.add actual
    system.process-stats --gc
    retained.size.repeat: | i/int |
      expect-equals #[i / 4 + 1, i % 4] retained[i]
    return
  connection.subscribe (3 + 2 * index) --cccd=(4 + 2 * index) --queue-limit=32: | stream/clients.Subscription |
    streams.add stream
    if index == 0:
      expect-throw "ATT_SUBSCRIPTION_BUSY":
        connection.subscribe 3 --cccd=4: unreachable
    nested connection streams
