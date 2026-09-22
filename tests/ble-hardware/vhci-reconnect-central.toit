// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.central
import ble.experimental.esp32
import ble.experimental.hci
import system
import .reconnect-exchange as fixture

main: run

// An optional public peer address uses HCI byte order and restricts discovery.
run --cycles/int=1000 --peer-address/ByteArray?=null:
  if not 1 <= cycles <= 10_000: throw "INVALID_ARGUMENT"
  if peer-address and peer-address.size != 6: throw "INVALID_ARGUMENT"
  controller := hci.Controller (esp32.Esp32Transport)
  host/central.Central? := null
  try:
    info := hci.initialize controller
    host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
        --early-acl-timeout=(Duration --ms=20)
    3.repeat: | cycle/int |
      fixture.exchange controller host cycle --peer-address=peer-address
    sleep --ms=10
    stats := system.process-stats --gc
    baseline := stats[system.STATS-INDEX-ALLOCATED-MEMORY]
    maximum := baseline
    minimum := baseline
    cycles.repeat: | cycle/int |
      fixture.exchange controller host (cycle + 3) --peer-address=peer-address
      sleep --ms=10
      system.process-stats --gc stats
      live := stats[system.STATS-INDEX-ALLOCATED-MEMORY]
      minimum = min minimum live
      maximum = max maximum live
      print "VHCI_RECONNECT_CENTRAL cycle=$(cycle + 1) live=$live free=$(stats[system.STATS-INDEX-SYSTEM-FREE-MEMORY]) largest=$(stats[system.STATS-INDEX-SYSTEM-LARGEST-FREE]) compacting-gcs=$(stats[system.STATS-INDEX-FULL-COMPACTING-GC-COUNT])"
      if live > baseline + 4096: throw "CONNECTION_MEMORY_GREW"
    print "VHCI_RECONNECT_CENTRAL COMPLETE cycles=$cycles warmup=3 echoes=$((cycles + 3) * 10) baseline=$baseline minimum=$minimum maximum=$maximum"
  finally:
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed
