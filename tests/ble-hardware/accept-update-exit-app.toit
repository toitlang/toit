// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.service.client as service
import system
import .accept-update-cancel as fixture

BEGIN ::= 1000
ENABLED ::= 1001
HELD ::= 1002

main arguments/List:
  if arguments.size != 1 or arguments[0] is not int or not 0 <= arguments[0] <= 2:
    throw "INVALID_ARGUMENT"
  run arguments[0]

run stage/int:
  with-timeout --ms=80_000:
    client := Client
    client.open --timeout=(Duration --s=10)
    try:
      client.begin stage
      session := client.configure
      session.add-service #[0xf0, 0xff]
      value := session.add-characteristic #[0xf1, 0xff] --read --dynamic-read
      before := system.process-stats
      data := fixture.payload stage 0
      response := fixture.scan-response stage 0
      print "ACCEPT_EXIT ADVERTISING stage=$stage"
      session.start data --scan-response=response
      client.enabled stage
      data.fill 0
      response.fill 0
      system.process-stats --gc
      if stage < 2:
        sleep --ms=4_000
        data = fixture.payload stage 1
        response = fixture.scan-response stage 1
        task::
          session.update-advertising data --scan-response=response
          throw "ACCEPT_EXIT_UNEXPECTED_REPLY"
        client.held stage
        data.fill 0
        response.fill 0
        system.process-stats --gc
        sleep --ms=1_500
        gcs := gc-count before
        if gcs < 2: throw "ACCEPT_EXIT_GC_MISSING"
        print "ACCEPT_EXIT EXIT stage=$stage pending=true full-gcs=$gcs"
        exit 0
      if session.peer != [#[0xa9, 0x56, 0xa3, 0x4b, 0x88, 0x8a], 0]: throw "WRONG_PEER"
      count := 0
      retained := []
      session.serve
          (: | request/service.Request |
            if request.handle != value or count >= 20: throw "ACCEPT_EXIT_UNEXPECTED_READ"
            bytes := #[count++, 42]
            if retained.size < 4: retained.add bytes
            system.process-stats --gc
            retained.size.repeat:
              if retained[it] != #[it, 42]: throw "ACCEPT_EXIT_RETAINED_CHANGED"
            request.reply bytes)
          (: | _ | unreachable)
          (: | _ _ | unreachable)
      if count != 20: throw "ACCEPT_EXIT_RECOVERY_INCOMPLETE"
      gcs := gc-count before
      if gcs < 21: throw "ACCEPT_EXIT_GC_MISSING"
      print "ACCEPT_EXIT RECOVERED reads=20 retained=4 full-gcs=$gcs"
    finally:
      if stage < 2: print "ACCEPT_EXIT_UNEXPECTED_FINALLY stage=$stage"
      client.close

gc-count before/List -> int:
  after := system.process-stats
  return after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]

class Client extends service.Client:
  constructor: super
  begin stage/int -> none: invoke_ BEGIN stage
  enabled stage/int -> none: invoke_ ENABLED stage
  held stage/int -> none: invoke_ HELD stage
