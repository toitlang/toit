// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.att
import ble.experimental.central
import ble.experimental.hci
import expect show *
import io
import system

import .ble-fixture as fixture

EXCHANGES ::= 1000

main:
  with-timeout --ms=30_000:
    run-echo

run-echo:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport)
  responder := task::
    fixture.status-reply transport fixture.create-command
    transport.received.add fixture.connection-event
    fixture.gatt-reply transport #[0x12, 4, 0, 1, 0] #[0x13]
    EXCHANGES.repeat: | sequence/int |
      bytes := value sequence
      fixture.att-sent transport (fixture.append-bytes #[0x12, 2, 0] bytes)
      transport.received.add (fixture.att-event #[0x13])
      // Change fragment boundaries across exchanges, including split headers.
      pdu := fixture.append-bytes #[14, 0, 4, 0, 0x1b, 3, 0] bytes
      split := 1 + sequence % (pdu.size - 1)
      transport.received.add (fixture.incoming-acl pdu[..split] --start)
      transport.received.add (fixture.incoming-acl pdu[split..])
    fixture.gatt-reply transport #[0x12, 4, 0, 0, 0] #[0x13]
    fixture.status-reply transport #[1, 6, 4, 3, 0x34, 2, 0x13]
    transport.received.add #[4, 5, 4, 0, 0x34, 2, 0x16]
  client/att.Client? := null
  try:
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    client = att.Client host link
    retained := []
    before := system.process-stats --gc
    client.subscribe 3 --cccd=4: | subscription/att.Subscription |
      EXCHANGES.repeat: | sequence/int |
        client.write 2 (value sequence)
        if sequence % 10 == 0:
          // Collect while the notification is in flight or already queued.
          system.process-stats --gc
        received := subscription.receive
        expect-equals (value sequence) received
        if sequence % 50 == 0: retained.add [sequence, received]
        retained.do: | sample/List |
          expect-equals (value sample[0]) sample[1]
      expect-equals 0 subscription.dropped
    after := system.process-stats --gc
    full-gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
    compacting-gcs := after[system.STATS-INDEX-FULL-COMPACTING-GC-COUNT] - before[system.STATS-INDEX-FULL-COMPACTING-GC-COUNT]
    expect full-gcs >= 100
    expect link.receive-high-water <= 32
    host.disconnect link
    retained.do: | sample/List |
      expect-equals (value sample[0]) sample[1]
    print "software-echo count=$EXCHANGES full-gcs=$full-gcs compacting-gcs=$compacting-gcs retained=$(retained.size)"
  finally:
    if client: client.close
    host.close
    responder.cancel

value sequence/int -> ByteArray:
  result := ByteArray 11
  io.LITTLE-ENDIAN.put-uint32 result 0 sequence
  result.replace 4 #[0x54, 0x6f, 0x69, 0x74, 0x48, 0x43, 0x49]
  return result
