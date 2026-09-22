// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.service.api
import ble.experimental.service.gatt-provider as providers
import ble.experimental.transport
import expect show *
import io
import monitor
import system
import .ble-hci-test as hci
import .ble-mtu-server-test as wire
import .ble-subscriptions-test as subscriptions

main:
  slots := List 16384
  set-max-heap-size_ (256 * 1024)
  failures := 0
  with-timeout --ms=30_000:
    256.repeat: | trial/int |
      provider := Provider
      session := provider.create-connection 1 [#[1, 2, 3, 4, 5, 6], 1, 1_000_000, 517]
      expected := ByteArray 512 --initial=42
      responder := task::
        hci.initialize-replies provider.radio
        hci.status-reply provider.radio hci.create-command
        provider.radio.received.add hci.connection-event
        wire.outgoing provider.radio (wire.exchange 2 517)
        wire.incoming provider.radio (wire.exchange 3 517)
        subscriptions.cccd provider.radio 4 1
        2.repeat:
          provider.radio.notify expected
          subscriptions.barrier provider.radio
        subscriptions.cccd provider.radio 4 0
        hci.status-reply provider.radio #[1, 6, 4, 3, 0x34, 2, 0x13]
        provider.radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x16]
      try:
        session.invoke api.CENTRAL-READY []
        token := (session.invoke api.CENTRAL-SUBSCRIBE [3, 4, false, 8])[1]
        arguments := [token]
        session.invoke api.CENTRAL-SUBSCRIPTION-READY arguments
        2.repeat:
          expect-equals [true, #[7]] (session.invoke api.CENTRAL-READ [1])
        expect-equals 40 provider.radio.fragments
        expect-equals [true, expected] (session.invoke api.CENTRAL-SUBSCRIPTION-NEXT arguments)
        filled := 0
        exhaustion := catch:
          while filled < slots.size:
            slots[filled] = ByteArray 8
            filled++
        if exhaustion != "OUT_OF_MEMORY" and exhaustion != "ALLOCATION_FAILED":
          throw "PRESSURE_NOT_REACHED"
        trial.repeat: slots[filled - 1 - it] = null
        received := null
        error := catch: received = session.invoke api.CENTRAL-SUBSCRIPTION-NEXT arguments
        slots.fill null
        system.process-stats --gc
        if error:
          if error != "OUT_OF_MEMORY" and error != "ALLOCATION_FAILED": throw error
          failures++
          with-timeout --ms=100:
            received = session.invoke api.CENTRAL-SUBSCRIPTION-NEXT arguments
        expect-equals [true, expected] received
        session.invoke api.CENTRAL-UNSUBSCRIBE arguments
        session.invoke api.CENTRAL-STOP []
      finally:
        slots.fill null
        responder.cancel
        session.close
        with-timeout --ms=1000:
          while not session.is-released: sleep --ms=1
      print "SERVICE_SUBSCRIPTION_PRESSURE ROUND trial=$trial"
    expect (0 < failures < 256)
    print "SERVICE_SUBSCRIPTION_PRESSURE COMPLETE rounds=256 failures=$failures"

class Provider extends providers.Provider:
  radio/PacedRadio ::= PacedRadio
  constructor: super
  open-transport -> transport.Transport: return radio

// Pace only this fixture's large notifications. A 512-byte value needs twenty
// 27-byte ACL fragments, exceeding FakeTransport's sixteen-packet queue if the
// producer runs without preemption. Pressure starts after both ATT barriers.
class PacedRadio extends hci.FakeTransport:
  taken_/monitor.Semaphore ::= monitor.Semaphore
  pending_/ByteArray? := null
  fragments/int := 0

  receive -> ByteArray:
    packet := super
    if packet == pending_: taken_.up
    return packet

  notify value/ByteArray -> none:
    pdu := #[0, 0, 4, 0, 0x1b, 3, 0] + value
    io.LITTLE-ENDIAN.put-uint16 pdu 0 (value.size + 3)
    offset := 0
    while offset < pdu.size:
      length := min 27 (pdu.size - offset)
      pending_ = hci.incoming-acl pdu[offset..offset + length] --start=(offset == 0)
      try:
        received.add pending_
        taken_.down
      finally:
        pending_ = null
      fragments++
      offset += length
