// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.service.api
import ble.experimental.service.gatt-provider as gatt
import ble.experimental.service.provider as rpc
import expect show *
import system
import .ble-shared-host-pressure-test as heap-fixture
import .ble-fixture as fixture

main:
  4.repeat: run it

run mode/int:
  provider := Provider
  session/rpc.Session? := null
  ready := [api.ADVERTISING-READY, api.SCAN-NEXT, api.CENTRAL-READY, api.PEER][mode]
  set-max-heap-size_ (256 * 1024)
  try:
    if mode == 0: session = provider.create-advertising 1 [#[], #[], 160, false]
    else if mode == 1: session = provider.create-scan 1 [1_000_000, false, 16, 16, false, null]
    else if mode == 2: session = provider.create-connection 1 [#[1, 2, 3, 4, 5, 6], 0, 1_000_000, 23]
    else: session = provider.create-session 1
    error := catch: session.invoke ready []
    provider.pressure.slots.fill null
    system.process-stats --gc
    expect provider.pressure.opened
    expect (error == "OUT_OF_MEMORY" or error == "ALLOCATION_FAILED")
    stopped := mode == 2 ? (catch: session.invoke api.CENTRAL-STOP []) : null
    session.close
    if mode == 2 and stopped:
      // Secondary cleanup OOM remains a reported error, and must not mark
      // this slot reusable merely because the transport close was attempted.
      expect (stopped == "OUT_OF_MEMORY" or stopped == "ALLOCATION_FAILED")
      expect (not session.is-released)
    else:
      with-timeout --ms=1000:
        while not session.is-released: sleep --ms=1
    expect provider.pressure.radio.closed
    print "SERVICE_INIT_PRESSURE COMPLETE mode=$mode cleanup-error=$stopped"
  finally:
    provider.pressure.slots.fill null
    if session: session.close
    provider.pressure.radio.close

class Provider extends gatt.Provider:
  pressure/heap-fixture.Factory ::= heap-fixture.Factory
  constructor: super

  open-transport -> fixture.FakeTransport:
    warm-stack 64
    return pressure.open-transport

// Exercise deeper worker frames before applying pressure. This does not reserve
// memory for later cleanup, which may still fail allocation.
warm-stack depth/int -> int:
  if depth == 0: return 0
  return 1 + (warm-stack (depth - 1))
