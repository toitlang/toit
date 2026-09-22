// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.service.api
import ble.experimental.service.gatt-provider as gatt
import ble.experimental.service.shared-host as shared
import ble.experimental.transport
import expect show *
import system
import .ble-service-init-pressure-test as fixture

main:
  provider := Provider
  failures := 0
  workers := 0
  set-max-heap-size_ (256 * 1024)
  96.repeat: | trial/int |
    session := provider.create-builder 1 "pressure"
    provider.slack = trial
    error := catch: session.invoke api.START [#[2, 1, 6], #[]]
    provider.slots.fill null
    system.process-stats --gc
    expect (provider.retained != null)
    if error:
      expect (error == "OUT_OF_MEMORY" or error == "ALLOCATION_FAILED")
      failures++
    else:
      workers++
      expect-throw "PROBE_OPEN_REACHED": session.invoke api.PEER []
    session.close
    with-timeout --ms=1_000:
      while not session.is-released: sleep --ms=1
    expect provider.retained.released
    // A fresh reservation after each trial must belong to a different lifetime.
    next := provider.reserve-shared-host
    expect (next != provider.retained)
    next.release
  expect (failures > 0 and workers > 0)
  print "SHARED_START_PRESSURE COMPLETE failures=$failures workers=$workers"

class Provider extends gatt.Provider:
  slots/List ::= List 16384
  slack/int := 0
  retained/shared.Host? := null

  reserve-peripheral-host -> shared.Host?:
    retained = reserve-shared-host
    fixture.warm-stack 64
    filled := 0
    failure := catch:
      while filled < slots.size:
        slots[filled] = ByteArray 8 --initial=42
        filled++
    if failure != "OUT_OF_MEMORY" and failure != "ALLOCATION_FAILED":
      throw "PRESSURE_NOT_REACHED"
    (min filled slack).repeat:
      filled--
      slots[filled] = null
    return retained

  open-transport -> transport.Transport:
    throw "PROBE_OPEN_REACHED"
