// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .mixed-service-client as fixture

main args/List:
  cycle/int := args[0]
  with-timeout --ms=60_000:
    client := fixture.Client
    client.open --timeout=(Duration --s=10)
    try:
      if cycle == -1:
        // No fixture advertises this static random address. The provider kills
        // this container only after observing successful initiating status.
        client.with-connection #[0x99, 0x58, 0x21, 0x45, 0x36, 0xc2] --address-type=1: unreachable
        throw "MIXED_PENDING_DEATH_UNEXPECTED_RETURN"
      client.with-connection #[0xae, 0xe0, 0x60, 0xac, 0xcd, 0x98]: | connection |
        fixture.check-values: connection.read 3
        client.signal (cycle * 4 + 1)
        // The provider terminates this container while this RPC is blocked.
        client.wait 15
        throw "MIXED_CENTRAL_DEATH_UNEXPECTED_RETURN"
    finally:
      print "MIXED_CENTRAL_DEATH FINALLY_RAN"
      client.signal 14
      client.close
