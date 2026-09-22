// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import monitor
import .mixed-service-client as fixture

main:
  with-timeout --ms=140_000:
    client := fixture.Client
    client.open --timeout=(Duration --s=10)
    session := client.configure --name="Toit HCI"
    ended := monitor.Latch
    acknowledged := [monitor.Latch, monitor.Latch]
    phase := 0
    worker/Task? := null
    try:
      session.add-service #[0xf0, 0xff]
      control := session.add-characteristic #[0xf1, 0xff] --read --write --value=#[0]
      if control != 12: throw "MIXED_FIXTURE_LAYOUT_CHANGED"
      session.start #[2, 1, 6]
      print "MIXED_CENTRAL_DEATH_PERIPHERAL ACCEPT_READY"
      session.peer
      client.signal 0
      worker = task::
        try:
          error := catch:
            session.serve
                (: | request | request.reject 0x0e)
                (: | request | request.reject 0x0e)
                (: | handle/int value/ByteArray |
                  if handle != control or phase == 0 or value != #[phase]:
                    throw "MIXED_UNEXPECTED_ACK"
                  ack/monitor.Latch := acknowledged[phase - 1]
                  if ack.has-value: throw "MIXED_DUPLICATE_ACK"
                  ack.set true)
          ended.set (error or true) --exception=(error != null)
        finally:
          critical-do --no-respect-deadline:
            if not ended.has-value: ended.set "MIXED_SERVER_ABORTED" --exception
      2.repeat: | cycle/int |
        client.wait (cycle * 4 + 2)
        fixture.check-values: session.value 3
        // Publish only after the provider has joined the killed central link.
        phase = cycle + 1
        session.set-value control #[phase]
        (acknowledged[cycle] as monitor.Latch).get
        client.signal (cycle * 4 + 3)
      ended.get
      print "MIXED_CENTRAL_DEATH_PERIPHERAL COMPLETE local-reads=200"
    finally:
      session.close
      if worker: worker.cancel
      client.close
