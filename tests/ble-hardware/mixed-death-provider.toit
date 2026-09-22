// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import monitor
import system
import system.containers
import .mixed-service-provider as fixture

main:
  [true, false].do: | pending-first/bool |
    with-timeout --ms=160_000: run pending-first
  print "MIXED_DEATH_PROVIDER COMPLETE rounds=2 kills=4"

run pending-first/bool:
  provider := Provider
  provider.install
  central/containers.Container? := null
  peripheral/containers.Container? := null
  retained := ByteArray 64 --initial=42
  collector := task --background::
    while true:
      sleep --ms=500
      system.process-stats --gc
      retained.do: if it != 42: throw "MIXED_PROVIDER_RETAINED_VALUE_CHANGED"
  try:
    central = fixture.start "mixed-central" []
    provider.wait 0
    2.repeat: | cycle/int |
      pending := pending-first and cycle == 0
      peripheral = fixture.start "mixed-periph" [cycle, pending]
      if pending:
        provider.wait (10 + cycle)
        provider.radio.first-enabled.get
        provider.publish (cycle * 4 + 1)
      provider.wait (cycle * 4 + 2)
      provider.wait (10 + cycle)
      before := Time.monotonic-us
      terminated := provider.radio.terminated
      if peripheral.stop != 0: throw "MIXED_PERIPHERAL_STOP"
      with-timeout --ms=4_000:
        while not provider.last-peripheral.is-released: sleep --ms=1
      if (provider.events[14] as monitor.Latch).has-value: throw "MIXED_DEATH_COOPERATIVE_CLEANUP"
      if pending and (provider.radio.terminated != terminated + 1 or provider.radio.last-status != 0x3c):
        throw "MIXED_DEATH_PENDING_BOUNDARY"
      print "MIXED_DEATH_PROVIDER KILLED cycle=$cycle pending=$pending cleanup-us=$(Time.monotonic-us - before)"
      peripheral.close
      peripheral = null
      provider.publish (cycle * 4 + 3)
      // This acknowledgement follows100 further reads on the surviving link.
      provider.wait (cycle * 4 + 4)
    if central.wait != 0: throw "MIXED_CENTRAL_EXIT"
    central.close
    central = null
    if provider.opens != 1 or provider.radio.closes != 1: throw "MIXED_CONTROLLER_LIFETIME"
    reads := pending-first ? 100 : 200
    if provider.radio.read-requests != reads or not provider.radio.command-errors.is-empty:
      throw "MIXED_RADIO_COUNTS"
    print "MIXED_DEATH_PROVIDER ROUND_COMPLETE pending-first=$pending-first central-reads=500 peer-reads=$reads opens=1 closes=1"
  finally:
    collector.cancel
    if peripheral:
      if not peripheral.is-closed: peripheral.stop
      peripheral.close
    if central:
      if not central.is-closed: central.stop
      central.close
    provider.uninstall

class Provider extends fixture.Provider:
  constructor:
    super
    7.repeat: events.add monitor.Latch

  publish event/int:
    (events[event] as monitor.Latch).set true
