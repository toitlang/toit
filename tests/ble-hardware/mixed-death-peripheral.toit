// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import monitor
import .mixed-service-client as fixture

main args/List:
  cycle/int := args[0]
  pending/bool := args[1]
  with-timeout --ms=100_000:
    client := fixture.Client
    client.open --timeout=(Duration --s=10)
    session := client.configure --name="Toit HCI"
    try:
      session.add-service #[0xf0, 0xff]
      control := session.add-characteristic #[0xf1, 0xff] --read --write --value=#[0]
      if control != 12: throw "MIXED_FIXTURE_LAYOUT_CHANGED"
      session.start #[2, 1, 6]
      if pending:
        client.signal (10 + cycle)
        // The provider kills this container while this RPC is waiting.
        session.peer
        throw "MIXED_PENDING_ACCEPT_CONNECTED"
      print "MIXED_DEATH_PERIPHERAL ACCEPT_READY cycle=$cycle"
      session.peer
      client.signal (cycle * 4 + 1)
      written := monitor.Latch
      task --background::
        session.serve
            (: | request | request.reject 0x0e)
            (: | request | request.reject 0x0e)
            (: | handle/int value/ByteArray |
              if handle != control or value != #[1]: throw "MIXED_UNEXPECTED_WRITE"
              written.set true)
      fixture.check-values: session.value 3
      written.get
      client.signal (10 + cycle)
      // Event15 is never published. No cooperative close precedes termination.
      client.wait 15
      throw "MIXED_DEATH_UNEXPECTED_RETURN"
    finally:
      print "MIXED_DEATH_PERIPHERAL FINALLY_RAN"
      client.signal 14
      session.close
      client.close
