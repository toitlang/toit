// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.central
import ble.experimental.hci
import ble.experimental.linux
import encoding.hex
import system

import .fixtures.vhci-central-provider as diagnostics
import .lifecycle as lifecycle
import .reconnect-exchange show exchange
import .connection-events as event-fixture

main args/List: run args

run args/List --trace/bool=false --deferred-events/bool=false:
  if trace and deferred-events: throw "INVALID_ARGUMENT"
  if not 1 <= args.size <= 3: throw "Usage: reconnect.toit <adapter index> [measured cycles [public peer address]]"
  cycles := args.size >= 2 ? (int.parse args[1]) : 20
  peer-address := args.size == 3 ? (hex.decode (args[2].replace --all ":" "")).reverse : null
  if peer-address and peer-address.size != 6: throw "INVALID_ARGUMENT"
  if not 1 <= cycles <= 10_000: throw "INVALID_ARGUMENT"
  radio := linux.LinuxTransport (int.parse args[0])
  events := deferred-events ? (event-fixture.ConnectionEvents radio) : null
  controller := hci.Controller (trace ? (diagnostics.Diagnostics radio --record-limit=(2 * (cycles + 3) + 8)) : (events or radio))
  host/central.Central? := null
  try:
    info := hci.initialize controller
    host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
        --early-acl-timeout=(Duration --ms=20)
    // Warm discovery, subscription, and task teardown before taking a baseline.
    3.repeat: | cycle/int | exchange controller host cycle --peer-address=peer-address
    sleep --ms=10
    descriptors := lifecycle.descriptor-count
    stats := system.process-stats --gc
    baseline := stats[system.STATS-INDEX-ALLOCATED-MEMORY]
    maximum := baseline
    minimum := baseline
    cycles.repeat: | cycle/int |
      exchange controller host cycle + 3 --peer-address=peer-address
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
    try:
      if host:
        host.close
        host.wait-closed
      else:
        controller.close
        controller.wait-closed
    finally:
      if events: events.dump
