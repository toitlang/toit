// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.service.client as service
import system
import .mixed-update-app as reads
import .mixed-update-exit-app as exit-app
import .accept-update-cancel as payloads

BASELINE ::= 1000
READ-WHILE-ADVERTISING ::= 1001
ADVERTISING-READS-DONE ::= 1002
ENABLED ::= 1003
FRESH-WINDOW ::= 1004
DROPPED ::= 1005
FAIL-READ ::= 1006

main arguments/List:
  with-timeout --ms=80_000:
    if arguments == [0]: outgoing
    else if arguments == [2]: exit-app.incoming 2
    else if arguments.size == 2 and arguments[0] == 1: doomed arguments[1]
    else: throw "INVALID_ARGUMENT"

outgoing:
  client := Client
  client.open --timeout=(Duration --s=10)
  before := system.process-stats
  try:
    client.with-connection #[0xae, 0xe0, 0x60, 0xac, 0xcd, 0x98]
        --timeout=(Duration --s=20): | connection/service.Connection |
      reads.read-batch connection 0
      client.control BASELINE
      client.control READ-WHILE-ADVERTISING
      reads.read-batch connection 1
      client.control ADVERTISING-READS-DONE
      client.control FAIL-READ
      started := Time.monotonic-us
      error := catch: connection.read 3
      elapsed := Time.monotonic-us - started
      if not ["HCI_CLOSED", "HCI_COMMAND_ABORTED", "DEADLINE_EXCEEDED", "ATT_CLOSED"].contains error:
        throw "MIXED_LOST_WRONG_READ_FAILURE"
      if elapsed > 5_000_000: throw "MIXED_LOST_SLOW_READ_FAILURE"
      print "MIXED_LOST_CENTRAL FAILED pending-read=true error=$error elapsed-us=$elapsed"
    gcs := exit-app.gc-count before
    if gcs < 20: throw "MIXED_LOST_GC_MISSING"
    print "MIXED_LOST_CENTRAL COMPLETE reads=200 full-gcs=$gcs"
  finally:
    client.close

doomed boundary/int:
  if boundary != 0 and boundary != 1: throw "INVALID_ARGUMENT"
  client := Client
  client.open --timeout=(Duration --s=10)
  before := system.process-stats
  try:
    session := client.configure
    session.add-service #[0xf0, 0xff]
    session.add-characteristic #[0xf1, 0xff] --read --value=#[0]
    data := payloads.payload boundary 0
    response := payloads.scan-response boundary 0
    print "MIXED_LOST ADVERTISING boundary=$boundary"
    session.start data --scan-response=response
    client.control ENABLED
    data.fill 0
    response.fill 0
    system.process-stats --gc
    sleep --ms=2_000
    client.control FRESH-WINDOW
    data = payloads.payload boundary 1
    response = payloads.scan-response boundary 1
    task::
      session.update-advertising data --scan-response=response
      throw "MIXED_LOST_UNEXPECTED_REPLY"
    client.control DROPPED
    data.fill 0
    response.fill 0
    system.process-stats --gc
    sleep --ms=1_500
    gcs := exit-app.gc-count before
    if gcs < 2: throw "MIXED_LOST_GC_MISSING"
    print "MIXED_LOST EXIT boundary=$boundary pending=true full-gcs=$gcs"
    exit 0
  finally:
    print "MIXED_LOST_UNEXPECTED_FINALLY"
    client.close

class Client extends service.Client:
  constructor: super
  control index/int -> none: invoke_ index null
