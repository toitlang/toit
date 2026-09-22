// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.esp32
import system
import .hci-server as fixture
import .vhci-central-provider as diagnostics

main: run

run --cycles/int=20 --warmup/int=0 --numbered-cycles/bool=false --trace/bool=false
    --receive-acl-packets/int=0:
  run-with-transport --cycles=cycles --warmup=warmup --numbered-cycles=numbered-cycles
      --receive-acl-packets=receive-acl-packets:
    radio := esp32.Esp32Transport
    trace ? (diagnostics.Diagnostics radio) : radio

// Opens one transport per cycle; the server owns its terminal cleanup.
run-with-transport --cycles/int=20 --warmup/int=0 --numbered-cycles/bool=false
    --receive-acl-packets/int=0 [open-radio]:
  if not 1 <= cycles <= 10_000 or not 0 <= warmup <= 100: throw "INVALID_ARGUMENT"
  baseline/int? := null
  maximum := 0
  (cycles + warmup).repeat: | cycle/int |
    radio := open-radio.call
    count := fixture.run radio
        --sequence-base=(numbered-cycles ? cycle * 10 : 0)
        --receive-acl-packets=receive-acl-packets
    if count != 10:
      throw "RECONNECT_COUNT_MISMATCH"
    stats := system.process-stats --gc
    live := stats[system.STATS-INDEX-ALLOCATED-MEMORY]
    if warmup > 0:
      if cycle == warmup - 1: baseline = live
      if cycle >= warmup:
        maximum = max maximum live
        if live > baseline + 4096: throw "RECONNECT_MEMORY_GREW"
    print "VHCI_RECONNECT cycle=$cycle allocated=$(stats[system.STATS-INDEX-ALLOCATED-MEMORY]) free=$(stats[system.STATS-INDEX-SYSTEM-FREE-MEMORY]) largest=$(stats[system.STATS-INDEX-SYSTEM-LARGEST-FREE]) compacting-gcs=$(stats[system.STATS-INDEX-FULL-COMPACTING-GC-COUNT])"
  print "VHCI_RECONNECT COMPLETE cycles=$cycles warmup=$warmup baseline=$baseline maximum=$maximum"
