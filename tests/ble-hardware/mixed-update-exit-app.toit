// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.service.client as service
import system
import .accept-update-cancel as payloads
import .mixed-update-app as reads

WAIT-BATCH ::= 1000
DONE ::= 1001
ENABLED ::= 1002
FRESH-WINDOW ::= 1003
HELD ::= 1004

main arguments/List:
  with-timeout --ms=155_000:
    if arguments == [0]: outgoing
    else if arguments.size == 2 and arguments[0] == 1: incoming arguments[1]
    else: throw "INVALID_ARGUMENT"

outgoing:
  client := Client
  client.open --timeout=(Duration --s=10)
  before := system.process-stats
  try:
    client.with-connection #[0xae, 0xe0, 0x60, 0xac, 0xcd, 0x98]
        --timeout=(Duration --s=20): | connection/service.Connection |
      6.repeat: | batch/int |
        if batch > 0: client.control WAIT-BATCH batch
        reads.read-batch connection batch
        client.control DONE batch
    gcs := gc-count before
    if gcs < 60: throw "MIXED_EXIT_GC_MISSING"
    print "MIXED_EXIT_CENTRAL COMPLETE reads=600 batches=6 full-gcs=$gcs"
  finally:
    client.close

incoming stage/int:
  if not 0 <= stage <= 2: throw "INVALID_ARGUMENT"
  client := Client
  client.open --timeout=(Duration --s=10)
  before := system.process-stats
  try:
    session := client.configure
    session.add-service #[0xf0, 0xff]
    value := session.add-characteristic #[0xf1, 0xff] --read --dynamic-read
    data := payloads.payload stage 0
    response := payloads.scan-response stage 0
    print "MIXED_EXIT ADVERTISING stage=$stage"
    session.start data --scan-response=response
    client.control ENABLED stage
    data.fill 0
    response.fill 0
    system.process-stats --gc
    if stage < 2:
      // The provider waits for100 concurrent outgoing reads before returning
      // ENABLED. Keep the initial payload observable on even faster peers.
      sleep --ms=2_000
      client.control FRESH-WINDOW stage
      data = payloads.payload stage 1
      response = payloads.scan-response stage 1
      task::
        session.update-advertising data --scan-response=response
        throw "MIXED_EXIT_UNEXPECTED_REPLY"
      client.control HELD stage
      data.fill 0
      response.fill 0
      system.process-stats --gc
      // The finite controller window expires during this hold. Client death
      // must consume the held reply, remove the set and never renew it.
      sleep --ms=1_500
      gcs := gc-count before
      if gcs < 2: throw "MIXED_EXIT_GC_MISSING"
      print "MIXED_EXIT EXIT stage=$stage pending=true full-gcs=$gcs"
      exit 0
    if session.peer != [#[0xa9, 0x56, 0xa3, 0x4b, 0x88, 0x8a], 0]: throw "WRONG_PEER"
    count := 0
    retained := []
    session.serve
        (: | request/service.Request |
          if request.handle != value or count >= 20: throw "MIXED_EXIT_UNEXPECTED_READ"
          bytes := #[count++, 42]
          if retained.size < 4: retained.add bytes
          system.process-stats --gc
          retained.size.repeat:
            if retained[it] != #[it, 42]: throw "MIXED_EXIT_RETAINED_CHANGED"
          request.reply bytes)
        (: | _ | unreachable)
        (: | _ _ | unreachable)
    if count != 20: throw "MIXED_EXIT_RECOVERY_INCOMPLETE"
    gcs := gc-count before
    if gcs < 21: throw "MIXED_EXIT_GC_MISSING"
    print "MIXED_EXIT RECOVERED reads=20 retained=4 full-gcs=$gcs"
  finally:
    if stage < 2: print "MIXED_EXIT_UNEXPECTED_FINALLY stage=$stage"
    client.close

gc-count before/List -> int:
  after := system.process-stats
  return after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]

class Client extends service.Client:
  constructor: super
  control index/int argument/int -> none: invoke_ index argument
