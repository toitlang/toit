// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.service.mixed-provider as mixed
import ble.experimental.transport
import system
import system.containers
import .establishment-idle as idle
import .mixed-service-provider as containers-fixture

main: run 1_000

// One diagnostic attempt per boot. Nonzero client exits remain visible and
// are not relabeled as successful BLE exchanges by this supervisor.
run delay/int:
  with-timeout --ms=25_000:
    provider := Provider
    provider.install
    child/containers.Container? := null
    code := -1
    before := system.process-stats
    collector := task --background::
      while true:
        sleep --ms=500
        system.process-stats --gc
    try:
      child = containers-fixture.start "link-probe-a" [delay]
      code = child.wait
    finally:
      critical-do --no-respect-deadline:
        collector.cancel
        if child: child.close
        provider.uninstall --wait
        if provider.radio: provider.radio.dump
    radio := provider.radio
    if provider.opens != 1 or not radio or radio.closes != 1:
      throw "ESTABLISHMENT_SERVICE_LIFETIME"
    after := system.process-stats
    gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
    print "ESTABLISHMENT_SERVICE RESULT delay-ms=$delay child-code=$code opens=1 closes=1 acl-sent=$(radio.acl-sent) first-acl-us=$(radio.first-acl-us) full-gcs=$gcs"

class Provider extends mixed.Provider:
  radio/Radio? := null
  opens/int := 0
  constructor: super
  receive-acl-packets -> int: return 4
  open-transport -> transport.Transport:
    opens++
    radio = Radio
    return radio

class Radio extends idle.Radio:
  first-acl-us/int := 0
  closes/int := 0
  constructor: super
  record-send packet/ByteArray -> none:
    super packet
    if acl-sent == 1 and packet[0] == 2: first-acl-us = Time.monotonic-us
  close -> none:
    if closes != 0: return
    closes++
    super
