// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.service.api
import expect show *
import system
import ..ble-service-central-test as fixture
import ..ble-hci-test as hci
import ..ble-mtu-server-test as wire
import ..ble-subscriptions-test as subscriptions

// Measures provider session handoff, including simulated peer work, without RPC.
main:
  with-timeout --ms=30_000:
    provider := fixture.Provider
    session := provider.create-connection 1 [#[1, 2, 3, 4, 5, 6], 1, 1_000_000, 517]
    expected := ByteArray 512 --initial=42
    responder := task::
      hci.initialize-replies provider.radio
      hci.status-reply provider.radio hci.create-command
      provider.radio.received.add hci.connection-event
      wire.outgoing provider.radio (wire.exchange 2 517)
      wire.incoming provider.radio (wire.exchange 3 517)
      subscriptions.cccd provider.radio 4 1
      1100.repeat:
        wire.outgoing provider.radio #[0x0a, 1, 0]
        wire.incoming provider.radio (#[0x1b, 3, 0] + expected)
        wire.incoming provider.radio #[0x0b, 7]
      subscriptions.cccd provider.radio 4 0
      hci.status-reply provider.radio #[1, 6, 4, 3, 0x34, 2, 0x13]
      provider.radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x16]
    try:
      session.invoke api.CENTRAL-READY []
      token := (session.invoke api.CENTRAL-SUBSCRIBE [3, 4, false, 8])[1]
      arguments := [token]
      session.invoke api.CENTRAL-SUBSCRIPTION-READY arguments
      baseline/List? := null
      retained/ByteArray? := null
      1100.repeat: | index/int |
        if index == 100: baseline = system.process-stats --gc
        expect-equals [true, #[7]] (session.invoke api.CENTRAL-READ [1])
        value/ByteArray := (session.invoke api.CENTRAL-SUBSCRIPTION-NEXT arguments)[1]
        expect-equals expected value
        if index == 100: retained = value
      after := system.process-stats
      allocated := after[system.STATS-INDEX-BYTES-ALLOCATED-IN-OBJECT-HEAP] -
          baseline[system.STATS-INDEX-BYTES-ALLOCATED-IN-OBJECT-HEAP]
      system.process-stats --gc
      expect-equals expected retained
      session.invoke api.CENTRAL-UNSUBSCRIBE arguments
      session.invoke api.CENTRAL-STOP []
      expect provider.radio.closed
      print "NOTIFICATION_ALLOCATION COMPLETE count=1000 bytes=512 allocated=$allocated retained=true"
    finally:
      responder.cancel
      session.close
