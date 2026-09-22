// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.central
import ble.experimental.hci
import ble.experimental.linux
import ble.experimental.transport
import encoding.hex
import system
import .connection-events as events
import .lifecycle as lifecycle
import .reconnect-exchange as fixture

// Diagnostic comparison only. A passing delayed run does not explain a plain
// failure. Stop on the first failed attempt; never retry or replay an exchange.
main args/List:
  if args.size != 3: throw "Usage: reconnect-idle <adapter index> <cycles> <public peer address>"
  cycles := int.parse args[1]
  address := (hex.decode (args[2].replace --all ":" "")).reverse
  if not 1 <= cycles <= 10_000 or address.size != 6: throw "INVALID_ARGUMENT"
  radio := Radio (linux.LinuxTransport (int.parse args[0]))
  controller := hci.Controller radio
  host/central.Central? := null
  try:
    info := hci.initialize controller
    host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
        --early-acl-timeout=(Duration --ms=20)
    3.repeat: exchange radio controller host it address
    sleep --ms=10
    descriptors := lifecycle.descriptor-count
    stats := system.process-stats --gc
    baseline := stats[system.STATS-INDEX-ALLOCATED-MEMORY]
    maximum := baseline
    minimum := baseline
    cycles.repeat: | cycle/int |
      exchange radio controller host (cycle + 3) address
      sleep --ms=10
      fds := lifecycle.descriptor-count
      system.process-stats --gc stats
      live := stats[system.STATS-INDEX-ALLOCATED-MEMORY]
      minimum = min minimum live
      maximum = max maximum live
      print "RECONNECT cycle=$(cycle + 1) descriptors=$fds live=$live"
      if fds != descriptors: throw "DESCRIPTOR_COUNT_CHANGED"
      if live > baseline + 4096: throw "CONNECTION_MEMORY_GREW"
    print "RECONNECT_COMPLETE cycles=$cycles warmup=3 echoes=$((cycles + 3) * 10) baseline=$baseline minimum=$minimum maximum=$maximum descriptors=$descriptors"
  finally:
    critical-do --no-respect-deadline:
      try:
        if host:
          host.close
          host.wait-closed
        else:
          controller.close
          controller.wait-closed
      finally:
        radio.dump

exchange radio/Radio controller/hci.Controller host/central.Central cycle/int address/ByteArray:
  before := radio.acl-sent
  fixture.exchange controller host cycle --peer-address=address: | link/central.Link |
    sleep --ms=1_000
    if link.has-ended:
      print "ESTABLISHMENT_IDLE_FAILURE cycle=$cycle acl-before-att=$(radio.acl-sent - before) att-created=false"
      throw "RECONNECT_IDLE_DISCONNECTED"

class Radio extends events.ConnectionEvents:
  acl-sent/int := 0
  constructor radio/transport.Transport: super radio
  record-send packet/ByteArray -> none:
    super packet
    if not packet.is-empty and packet[0] == 2: acl-sent++
