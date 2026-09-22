// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.service.client as clients
import expect show *
import system
import .ble-service-central-test as fixture
import .ble-hci-test as hci
import .ble-subscriptions-test as subscriptions
import .ble-mtu-server-test as wire

REPORT ::= 1000

main:
  failures := 0
  with-timeout --ms=30_000:
    64.repeat: | trial/int |
      provider := Provider
      provider.install
      responder := task::
        hci.initialize-replies provider.radio
        hci.status-reply provider.radio hci.create-command
        provider.radio.received.add hci.connection-event
        wire.outgoing provider.radio (wire.exchange 2 517)
        wire.incoming provider.radio (wire.exchange 3 517)
        subscriptions.cccd provider.radio 4 1
        wire.incoming provider.radio (#[0x1b, 3, 0] + (ByteArray 512 --initial=42))
        subscriptions.barrier provider.radio
        subscriptions.cccd provider.radio 4 0
        hci.status-reply provider.radio #[1, 6, 4, 3, 0x34, 2, 0x13]
        provider.radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x16]
      try:
        spawn:: run-client trial
        provider.uninstall --wait
        expect provider.reported
        expect provider.radio.closed
        if provider.error: failures++
      finally:
        responder.cancel
        provider.uninstall
    print "NOTIFICATION_RPC_PRESSURE SUMMARY rounds=64 failures=$failures"
    expect (0 < failures < 64)
    print "NOTIFICATION_RPC_PRESSURE COMPLETE"

run-client trial/int:
  slots := List 16384
  client := Client
  client.open
  try:
    connection := client.connect #[1, 2, 3, 4, 5, 6] --address-type=1 --mtu-limit=517
    error := null
    connection.subscribe 3 --cccd=4: | stream |
      expect-equals #[7] (connection.read 1)
      set-max-heap-size_ (256 * 1024)
      filled := 0
      exhaustion := catch:
        while filled < slots.size:
          slots[filled] = ByteArray 8
          filled++
      if exhaustion != "ALLOCATION_FAILED" and exhaustion != "OUT_OF_MEMORY":
        throw "PRESSURE_NOT_REACHED"
      (trial * 64).repeat: slots[filled - 1 - it] = null
      received := null
      error = catch: received = stream.receive
      slots.fill null
      system.process-stats --gc
      if error and error != "ALLOCATION_FAILED" and error != "OUT_OF_MEMORY": throw error
      if not error: expect-equals (ByteArray 512 --initial=42) received
      // Delivery is uncertain after RPC failure. Exit the scope without retry.
    connection.disconnect
    client.report error
  finally:
    slots.fill null
    client.close

class Client extends clients.Client:
  constructor: super
  report error -> none: invoke_ REPORT error

class Provider extends fixture.Provider:
  reported/bool := false
  error := null
  constructor: super
  handle index/int arguments/any --gid/int --client/int -> any:
    if index != REPORT: return super index arguments --gid=gid --client=client
    // Assert cleanup before process exit or client disconnect can perform it.
    expect radio.closed
    reported = true
    error = arguments
    return null
