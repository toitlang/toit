// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import rpc
import system.services

SELECTOR ::= services.ServiceSelector
    --uuid="c91ac783-f489-4e20-8fc6-1ad31990d654"
    --major=0
    --minor=0

main:
  with-timeout --ms=5_000:
    provider := Provider
    provider.install
    victim := Client
    victim.open
    try:
      handle := victim.create
      victim-id := victim.id
      provider-pid := Process.current.id
      spawn::
        attacker := Client
        attacker.open
        try:
          // Knowing another process's client and resource handles does not
          // grant permission to invoke it, close its resource or close it.
          expect-throw "SERVICE_CLIENT_NOT_OWNED":
            rpc.invoke provider-pid 302 [victim-id, 1, handle]
          expect-throw "SERVICE_CLIENT_NOT_OWNED":
            rpc.invoke provider-pid 303 [victim-id, handle]
          expect-throw "SERVICE_CLIENT_NOT_OWNED":
            rpc.invoke provider-pid 301 victim-id
          own := attacker.create
          expect-equals 42 (attacker.read own)
          attacker.done
        finally:
          attacker.close
      provider.finished.get
      expect-equals 42 (victim.read handle)
      expect (not provider.victim.closed)
      rpc.invoke provider-pid 303 [victim-id, handle]
      expect provider.victim.closed
      rpc.invoke provider-pid 303 [victim-id, handle]
      victim.close
      victim.close
    finally:
      victim.close
      provider.uninstall

class Client extends services.ServiceClient:
  constructor: super SELECTOR
  create -> int: return invoke_ 0 null
  read handle/int -> int: return invoke_ 1 handle
  done -> none: invoke_ 2 null

class Provider extends services.ServiceProvider implements services.ServiceHandler:
  finished/monitor.Latch ::= monitor.Latch
  victim/Resource? := null
  constructor:
    super "client-ownership-test" --major=0 --minor=0
    provides SELECTOR --handler=this
  handle index/int arguments/any --gid/int --client/int -> any:
    if index == 0:
      result := Resource this client
      if not victim: victim = result
      return result
    if index == 1:
      value := (resource client arguments) as Resource
      expect (not value.closed)
      return 42
    expect-equals 2 index
    finished.set true
    return null

class Resource extends services.ServiceResource:
  closed/bool := false
  constructor provider/Provider client/int: super provider client
  on-closed -> none: closed = true
