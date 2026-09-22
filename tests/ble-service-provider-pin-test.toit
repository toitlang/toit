// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.service.api as api
import ble.experimental.service.client as ble
import expect show *
import system.services
import .services-provider-pin-test as fixture

main:
  with-timeout --ms=5_000:
    expect-throw "INVALID_ARGUMENT": ble.Client --provider-pid=-1
    expect-throw "INVALID_ARGUMENT": ble.Client --provider-pid=0x8000_0000
    control := fixture.Provider 42 0
    control.install
    trusted := Provider 1 0
    trusted.install
    pid := Process.current.id
    spawn::
      impostor := Provider 2 100
      impostor.install
      channel := fixture.Client --provider-pid=pid
      channel.open
      try:
        channel.signal
        channel.wait
      finally:
        channel.close
        impostor.uninstall
    control.ready.get
    ordinary := ble.Client
    pinned := ble.Client --provider-pid=pid
    try:
      ordinary.open
      expect-equals 2 ordinary.capabilities.max-sessions
      pinned.open
      expect-equals 1 pinned.capabilities.max-sessions
      pinned.close
      trusted.uninstall
      expect-equals "absent" (pinned.open --if-absent=: "absent")
      expect-equals "absent" (pinned.open --timeout=(Duration --ms=30) --if-absent=: "absent")
      expect-equals 2 ordinary.capabilities.max-sessions
      trusted.install
      pinned.open
      expect-equals 1 pinned.capabilities.max-sessions
    finally:
      control.release.set true
      pinned.close
      ordinary.close
      trusted.uninstall
      control.uninstall

// Two real processes claim the actual BLE selector and identical service name.
class Provider extends services.ServiceProvider implements services.ServiceHandler:
  sessions_/int
  constructor .sessions_ priority/int:
    super "ble-pin-fixture" --major=0 --minor=20
    provides api.SELECTOR --handler=this --priority=priority
  handle index/int arguments/any --gid/int --client/int -> any:
    if index != api.CAPABILITIES: throw "UNEXPECTED_OPERATION"
    return [api.CAP-GATT-CENTRAL, 60_000_000, 512, 517, sessions_]
