// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.linux
import ble.experimental.transport
import ble.experimental.service.gatt-provider as service
import system

import .hci-trace as trace

// This hardware fixture explicitly owns hci0; the launcher verifies its MAC.
main: run

run --trace/bool=false:
  provider := Provider --trace=trace
  provider.install
  print "BLE_SERVICE READY adapter=0"
  before := system.process-stats
  gcs := 0
  collector := task --background::
    while true:
      sleep --ms=900
      system.process-stats --gc
      gcs++
  try:
    provider.uninstall --wait
  finally:
    collector.cancel
    provider.uninstall
  after := system.process-stats
  print "BLE_SERVICE COMPLETE requested-gcs=$gcs full-gcs=$(after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT])"
  print "BLE_SERVICE process-stats=$after"

class Provider extends service.Provider:
  trace_/bool

  constructor --trace/bool=false:
    trace_ = trace
    super

  open-transport -> transport.Transport:
    radio := linux.LinuxTransport 0
    return trace_ ? (trace.Trace radio) : radio

  // USB event and ACL endpoints can complete out of order on this dongle.
  early-acl-timeout -> Duration?: return Duration --ms=20

