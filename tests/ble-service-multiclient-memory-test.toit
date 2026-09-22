// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import system
import ble.experimental.service.client as clients
import .ble-hci-test as fixture
import .ble-multilink-test as links
import .ble-service-multiclient-test as shared

CYCLES ::= 1000

main:
  with-timeout --ms=30_000:
    exercise

exercise:
  provider := shared.Provider
  provider.install
  rotating := clients.Client
  stable := clients.Client
  rotating.open
  stable.open
  peer-ended := monitor.Latch
  responder := task::
    try:
      radio := provider.radio
      fixture.initialize-replies radio
      links.establish radio 2 0x235
      CYCLES.repeat: | cycle/int |
        links.establish radio 1 0x234
        shared.sent radio 0x234 #[0x0a, 3, 0]
        shared.incoming radio 0x234 #[0x0b, cycle % 251]
        shared.disconnect radio 0x234
        shared.sent radio 0x235 #[0x0a, 3, 0]
        shared.incoming radio 0x235 (#[0x0b] + (payload cycle))
      shared.disconnect radio 0x235
    finally:
      critical-do --no-respect-deadline: peer-ended.set true
  stats := system.process-stats --gc
  initial-gcs := stats[system.STATS-INDEX-FULL-GC-COUNT]
  baseline := 0
  peak := 0
  retained := List 10
  try:
    b := stable.connect (links.address 2) --address-type=1
    CYCLES.repeat: | cycle/int |
      rotating.with-connection (links.address 1) --address-type=1: | a |
        expect-equals #[cycle % 251] (a.read 3)
      value := b.read 3
      expect-equals (payload cycle) value
      retained[cycle % 10] = [cycle, value]
      retained.do: | sample/List? |
        if sample: expect-equals (payload sample[0]) sample[1]
      expect (not provider.radio.closed)
      system.process-stats --gc stats
      live := stats[system.STATS-INDEX-ALLOCATED-MEMORY]
      if cycle == 19:
        baseline = live
        peak = live
      else if cycle > 19:
        peak = max peak live
        expect (peak <= baseline + 4096)
    expect-equals 1 provider.opens
    b.disconnect
    peer-ended.get
    expect provider.radio.closed
    gcs := stats[system.STATS-INDEX-FULL-GC-COUNT] - initial-gcs
    expect (gcs >= CYCLES)
    print "service-multiclient-memory cycles=$CYCLES stable-reads=$CYCLES full-gcs=$gcs baseline=$baseline peak=$peak retained=10"
  finally:
    rotating.close
    stable.close
    responder.cancel
    provider.uninstall

payload cycle/int -> ByteArray: return ByteArray 20: (cycle + it) % 251
