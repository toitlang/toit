// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.service.client as service
import system
import .connectable-update-app as payloads

BASELINE ::= 1000
WAIT-BASELINE ::= 1001
PHASE ::= 1002
WAIT-PHASE ::= 1003
DONE ::= 1004
WAIT-DONE ::= 1005
ENDED ::= 1006
WAIT-ENDED ::= 1007

main arguments/List:
  with-timeout --ms=90_000:
    if arguments == [0]: outgoing
    else if arguments == [1]: incoming
    else: throw "INVALID_ARGUMENT"

outgoing:
  client := Client
  client.open --timeout=(Duration --s=10)
  before := system.process-stats
  try:
    if not client.capabilities.mixed-roles: throw "MIXED_UPDATE_UNSUPPORTED"
    client.with-connection #[0xae, 0xe0, 0x60, 0xac, 0xcd, 0x98]
        --timeout=(Duration --s=20): | connection/service.Connection |
      read-batch connection 0
      client.control BASELINE
      4.repeat: | phase/int |
        client.control WAIT-PHASE phase
        read-batch connection (phase + 1)
        client.control DONE phase
      client.control WAIT-ENDED
      read-batch connection 5
    after := system.process-stats
    gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
    if gcs < 60: throw "MIXED_UPDATE_GC_MISSING"
    print "MIXED_UPDATE_CENTRAL COMPLETE reads=600 batches=6 full-gcs=$gcs"
  finally:
    client.close

read-batch connection/service.Connection batch/int:
  before := system.process-stats
  retained := []
  100.repeat: | index/int |
    sequence := batch * 100 + index
    value := connection.read 3
    if value != #[sequence & 0xff, sequence >> 8, 42]: throw "MIXED_UPDATE_VALUE_CHANGED"
    if retained.size < 4: retained.add value
    if index % 10 == 0: system.process-stats --gc
  retained.size.repeat:
    sequence := batch * 100 + it
    if retained[it] != #[sequence & 0xff, sequence >> 8, 42]: throw "MIXED_UPDATE_RETAINED_CHANGED"
  after := system.process-stats
  gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
  if gcs < 10: throw "MIXED_UPDATE_GC_MISSING"
  print "MIXED_UPDATE_CENTRAL BATCH index=$batch reads=100 retained=4 full-gcs=$gcs"

incoming:
  client := Client
  client.open --timeout=(Duration --s=10)
  try:
    client.control WAIT-BASELINE
    session := client.configure
    session.add-service #[0xf0, 0xff]
    value := session.add-characteristic #[0xf1, 0xff] --read --write --value=#[0]
    before := system.process-stats
    print "CONNECTABLE_UPDATE ADVERTISING"
    4.repeat: | phase/int |
      data := payloads.payload phase
      response := payloads.scan-response phase
      if phase == 0: session.start data --scan-response=response
      else if not (session.update-advertising data --scan-response=response):
        throw "MIXED_UPDATE_EARLY_CONNECTION"
      data.fill 0
      response.fill 0
      system.process-stats --gc
      print "CONNECTABLE_UPDATE APPLIED phase=$phase gc=true"
      client.control PHASE phase
      if phase < 3:
        sleep --ms=4_000
        client.control WAIT-DONE phase
    if session.peer != [#[0xa9, 0x56, 0xa3, 0x4b, 0x88, 0x8a], 0]: throw "WRONG_PEER"
    if session.update-advertising #[1]: throw "MIXED_UPDATE_AFTER_CONNECTION"
    count := 0
    retained := []
    session.serve
        (: | _ | unreachable)
        (: | _ | unreachable)
        (: | handle/int bytes/ByteArray |
          if handle != value or bytes != #[count, 42, 43]: throw "MIXED_UPDATE_WRONG_ECHO"
          if retained.size < 4: retained.add bytes
          count++
          system.process-stats --gc
          retained.size.repeat:
            if retained[it] != #[it, 42, 43]: throw "MIXED_UPDATE_ECHO_RETAINED_CHANGED")
    if count != 100: throw "MIXED_UPDATE_INCOMPLETE"
    session.close
    client.control ENDED
    after := system.process-stats
    gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
    if gcs < 104: throw "MIXED_UPDATE_GC_MISSING"
    print "CONNECTABLE_UPDATE_APP COMPLETE writes=100 retained=4 full-gcs=$gcs"
  finally:
    client.close

class Client extends service.Client:
  constructor: super
  control index/int argument/any=null -> none: invoke_ index argument
