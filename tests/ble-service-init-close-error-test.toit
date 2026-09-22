// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.service.api
import ble.experimental.service.provider as rpc
import expect show *
import system
import .ble-service-init-pressure-test as init-fixture
import .ble-fixture as fixture

main:
  4.repeat: run it

run mode/int:
  provider := Provider
  session/rpc.Session? := null
  ready := [api.ADVERTISING-READY, api.SCAN-NEXT, api.CENTRAL-READY, api.PEER][mode]
  stop := [api.ADVERTISING-STOP, api.SCAN-STOP, api.CENTRAL-STOP, 0][mode]
  opening := [api.OPEN-ADVERTISING, api.OPEN-SCAN, api.CONNECT, api.OPEN][mode]
  arguments := [[#[], #[], 160, false], [1_000_000, false, 16, 16, false, null],
    [#[1, 2, 3, 4, 5, 6], 0, 1_000_000, 23], null][mode]
  set-max-heap-size_ (256 * 1024)
  try:
    session = provider.handle opening arguments --gid=1 --client=1
    error := catch: session.invoke ready []
    provider.pressure.slots.fill null
    system.process-stats --gc
    expect provider.pressure.opened
    expect (error == "OUT_OF_MEMORY" or error == "ALLOCATION_FAILED")
    stopped := null
    if mode != 3:
      stopped = catch: session.invoke stop []
      // Central may fail allocation before it can enter the injected close.
      // Advertising retains its primary error; scan exposes the close error.
      if mode == 2:
        expect (stopped == "TRANSPORT_CLOSE_FAILED" or stopped == "OUT_OF_MEMORY" or stopped == "ALLOCATION_FAILED")
      else:
        expect-equals (mode == 0 ? error : "TRANSPORT_CLOSE_FAILED") stopped
    closed := catch: session.close
    if mode == 3: expect-equals "TRANSPORT_CLOSE_FAILED" closed
    else: expect-null closed
    if mode != 2 or stopped == "TRANSPORT_CLOSE_FAILED": expect (provider.radio.closes > 0)
    expect (not provider.radio.closed)
    expect (not session.is-released)
    expect-throw "GATT_SERVICE_BUSY":
      provider.handle api.OPEN-BUILDER "replacement" --gid=1 --client=2
    print "SERVICE_INIT_CLOSE_ERROR COMPLETE mode=$mode closes=$(provider.radio.closes) stop=$stopped"
  finally:
    provider.pressure.slots.fill null
    if session: catch: session.close
    provider.radio.finish

class Provider extends init-fixture.Provider:
  radio/Radio? := null
  constructor:
    super
    radio = Radio this.pressure.slots

  open-transport -> Radio:
    init-fixture.warm-stack 64
    this.pressure.open-transport
    return radio

class Radio extends fixture.FakeTransport:
  slots_/List
  closes/int := 0
  fail/bool := true

  constructor .slots_: super

  close -> none:
    // Release ballast only once cleanup reaches the retained transport. This
    // isolates transport failure from secondary error-delivery allocation OOM.
    slots_.fill null
    closes++
    if fail: throw "TRANSPORT_CLOSE_FAILED"
    super

  finish -> none:
    fail = false
    close
