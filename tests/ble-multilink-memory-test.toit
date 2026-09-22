// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.att
import ble.experimental.central
import ble.experimental.hci
import expect show *
import monitor
import system
import .ble-fixture as fixture
import .ble-multilink-test as wire

CYCLES ::= 200

main:
  with-timeout --ms=30_000:
    exercise

exercise:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport) --link-limit=2 --acl-count=2
  peer-ended := monitor.Latch
  responder := task::
    try:
      wire.establish transport 2 0x235
      CYCLES.repeat: | cycle/int |
        wire.establish transport 1 0x234
        fixture.att-sent transport #[0x0a, 3, 0]
        transport.received.add (fixture.att-event #[0x0b, cycle % 251])
        seen-read := false
        seen-disconnect := false
        2.repeat:
          packet := transport.sent.take
          if packet[0] == 1:
            expect (not seen-disconnect)
            expect-equals #[1, 6, 4, 3, 0x34, 2, 0x13] packet
            transport.received.add #[4, 15, 4, 0, 1, 6, 4]
            seen-disconnect = true
          else:
            expect (not seen-read)
            expect-equals #[2, 0x35, 2, 7, 0, 3, 0, 4, 0, 0x0a, 3, 0] packet
            wire.completed transport 0x235
            wire.incoming transport 0x235 (#[21, 0, 4, 0, 0x0b] + (payload cycle)) --start
            seen-read = true
        wire.ended transport 0x234
    finally:
      critical-do --no-respect-deadline: peer-ended.set true
  stable/att.Client? := null
  previous/att.Client? := null
  stats := system.process-stats --gc
  initial-gcs := stats[system.STATS-INDEX-FULL-GC-COUNT]
  retained := List 10
  baseline := 0
  maximum := 0
  minimum := 0
  try:
    stable-link := host.connect (wire.address 2) --address-type=1
    stable = att.Client host stable-link
    CYCLES.repeat: | cycle/int |
      link := host.connect (wire.address 1) --address-type=1
      // A prior adapter must not touch the replacement lifetime or stable peer.
      if previous: previous.close
      client := att.Client host link
      previous = client
      expect-equals #[cycle % 251] (client.read 3)
      client.close
      client.wait-closed
      bytes := stable.read 3
      expect-equals (payload cycle) bytes
      retained[cycle % 10] = [cycle, bytes]
      expect-equals 0x13 link.wait-disconnected
      expect (stable-link.connected and not transport.closed)
      retained.do: | sample/List? |
        if sample: expect-equals (payload sample[0]) sample[1]
      system.process-stats --gc stats
      live := stats[system.STATS-INDEX-ALLOCATED-MEMORY]
      if cycle == 19:
        baseline = live
        minimum = live
        maximum = live
      else if cycle > 19:
        minimum = min minimum live
        maximum = max maximum live
        // Bound retained graphs, allowing runtime scheduling/bookkeeping noise.
        expect maximum <= baseline + 4096
    peer-ended.get
    gcs := stats[system.STATS-INDEX-FULL-GC-COUNT] - initial-gcs
    expect gcs >= CYCLES
    print "software-multilink cycles=$CYCLES stable-reads=$CYCLES retained=10 full-gcs=$gcs baseline=$baseline min=$minimum max=$maximum"
  finally:
    if previous: previous.close
    if stable: stable.close
    responder.cancel
    host.close
    host.wait-closed
    peer-ended.get

payload cycle/int -> ByteArray: return ByteArray 20: (cycle + it) % 251
