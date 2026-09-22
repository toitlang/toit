// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import monitor
import .mixed-service-client as fixture

main args/List:
  run args

run args/List --secure/bool=false --mtu-limit/int=23:
  cycle/int := args[0]
  if not 0 <= cycle <= 1: throw "INVALID_ARGUMENT"
  with-timeout --ms=100_000:
    client := fixture.Client
    client.open --timeout=(Duration --s=10)
    session := client.configure --name="Toit HCI" --mtu-limit=mtu-limit
    written := monitor.Latch
    ended := monitor.Latch
    worker/Task? := null
    try:
      session.add-service #[0xf0, 0xff]
      if secure:
        protected := session.add-characteristic #[0xf2, 0xff] --read --authenticated --value="Toit HCI".to-byte-array
        if protected != 12: throw "MIXED_FIXTURE_LAYOUT_CHANGED"
      control := session.add-characteristic #[0xf1, 0xff] --read --write --write-command=secure --value=#[0]
      if control != (secure ? 14 : 12): throw "MIXED_FIXTURE_LAYOUT_CHANGED"
      session.start #[2, 1, 6]
      print "MIXED_PERIPHERAL ACCEPT_READY cycle=$cycle"
      session.peer
      client.signal (cycle * 4 + 1)
      worker = task::
        try:
          error := catch:
            session.serve
                (: | request | request.reject 0x0e)
                (: | request | request.reject 0x0e)
                (: | handle/int value/ByteArray |
                  if handle != control or value != #[1]: throw "MIXED_UNEXPECTED_WRITE"
                  written.set true)
          if error and not session.is-closed: throw error
        finally:
          critical-do --no-respect-deadline: ended.set true
      fixture.check-values: session.value 3
      written.get
      if secure and not session.security.authenticated: throw "MIXED_SECURITY_LOST"
      client.wait (cycle * 4 + 2)
      session.close
      ended.get
      // The fixture provider waits for physical cleanup before publishing this.
      client.signal (cycle * 4 + 3)
      print "MIXED_PERIPHERAL COMPLETE cycle=$cycle local-reads=100"
    finally:
      session.close
      if worker: worker.cancel
      client.close
