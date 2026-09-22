// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import system.services

SELECTOR ::= services.ServiceSelector
    --uuid="54c2ff3a-56fc-4a7d-92ef-7f29aeb69973"
    --major=0
    --minor=0

main:
  with-timeout --ms=30_000:
    100.repeat: | iteration/int |
      provider := Provider
      // Each fresh client process must install its notification proxy while
      // this process concurrently publishes the service being discovered.
      spawn::
        client := Client
        client.open --timeout=(Duration --ms=200)
        try:
          expect-equals 42 client.read
        finally:
          client.close
      if iteration % 2 == 0: yield
      else: sleep --ms=1
      provider.install
      try:
        with-timeout --ms=500: provider.uninstall --wait
      finally:
        provider.uninstall

class Client extends services.ServiceClient:
  constructor:
    super SELECTOR

  read -> int: return invoke_ 0 null

class Provider extends services.ServiceProvider implements services.ServiceHandler:
  constructor:
    super "discovery-race-test" --major=0 --minor=0
    provides SELECTOR --handler=this

  handle index/int arguments/any --gid/int --client/int -> any:
    expect-equals 0 index
    return 42
