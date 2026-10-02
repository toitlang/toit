// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import system.services

SELECTOR ::= services.ServiceSelector
    --uuid="25f925b0-d201-4217-9247-ea9ff81a30c7"
    --major=0
    --minor=0

main:
  with-timeout --ms=5_000:
    expect-throw "INVALID_ARGUMENT": Client --provider-pid=-1
    expect-throw "INVALID_ARGUMENT": Client --provider-pid=0x8000_0000
    trusted := Provider 42 0
    trusted.install
    pid := Process.current.id
    spawn::
      impostor := Provider 666 100
      impostor.install
      control := Client --provider-pid=pid
      control.open
      try:
        control.signal
        control.wait
      finally:
        control.close
        impostor.uninstall
    trusted.ready.get
    ordinary := Client
    pinned := Client --provider-pid=pid
    try:
      ordinary.open
      expect-equals 666 ordinary.read
      pinned.open
      expect-equals 42 pinned.read
      pinned.close
      trusted.uninstall
      // The matching higher-priority impostor remains registered. Neither
      // immediate nor waiting discovery may fall back to that process.
      expect-equals "absent" (pinned.open --if-absent=: "absent")
      expect-equals "absent" (pinned.open --timeout=(Duration --ms=30) --if-absent=: "absent")
      expect-equals 666 ordinary.read
      task::
        sleep --ms=20
        trusted.install
      pinned.open --timeout=(Duration --ms=500)
      expect-equals 42 pinned.read
    finally:
      trusted.release.set true
      pinned.close
      ordinary.close
      trusted.uninstall

class Client extends services.ServiceClient:
  constructor --provider-pid/int?=null:
    super SELECTOR --provider-pid=provider-pid
  read -> int: return invoke_ 0 null
  signal: invoke_ 1 null
  wait: invoke_ 2 null

class Provider extends services.ServiceProvider implements services.ServiceHandler:
  value_/int
  ready/monitor.Latch ::= monitor.Latch
  release/monitor.Latch ::= monitor.Latch
  constructor .value_ priority/int:
    // Both providers deliberately claim the same name and selector.
    super "provider-pin-test" --major=0 --minor=0
    provides SELECTOR --handler=this --priority=priority
  handle index/int arguments/any --gid/int --client/int -> any:
    if index == 0: return value_
    if index == 1:
      ready.set true
      return null
    return release.get
