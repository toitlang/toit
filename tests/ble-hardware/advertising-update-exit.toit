// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.service.client as service
import system
import .advertising-update as fixture

WAIT-PREVIOUS ::= 1000
WAIT-HELD ::= 1001

run mode/int:
  with-timeout --ms=60_000:
    client := Client
    client.open --timeout=(Duration --s=10)
    try:
      if mode == 1: client.wait-previous
      advertiser/service.Advertising? := null
      3.repeat: | phase/int |
        data := fixture.payload mode phase
        response := mode == 1 ? (fixture.scan-response mode phase) : #[]
        if phase == 0:
          advertiser = client.start-advertising data --scannable=(mode == 1) --scan-response=response
        else:
          advertiser.update data --scan-response=response
        data.fill 0
        response.fill 0
        collect
        print "ADVERTISING_UPDATE APPLIED mode=$mode phase=$phase gc=true"
        sleep --ms=5_000
      task::
        advertiser.update #[]
        throw "ADVERTISING_UPDATE_EXIT_UNEXPECTED_REPLY"
      client.wait-held mode
      collect
      print "ADVERTISING_UPDATE PENDING mode=$mode phase=3 gc=true"
      // The aggregate command deadline is three seconds. Leave time for the
      // reference to observe empty payloads, then die before that deadline.
      sleep --ms=1_500
      print "ADVERTISING_UPDATE EXIT mode=$mode pending=true"
      exit 0
    finally:
      print "ADVERTISING_UPDATE_EXIT_UNEXPECTED_FINALLY mode=$mode"
      client.close

collect:
  before := system.process-stats
  after := system.process-stats --gc
  if after[system.STATS-INDEX-FULL-GC-COUNT] <= before[system.STATS-INDEX-FULL-GC-COUNT]:
    throw "ADVERTISING_UPDATE_GC_MISSING"

class Client extends service.Client:
  constructor: super
  wait-previous -> none: invoke_ WAIT-PREVIOUS null
  wait-held mode/int -> none: invoke_ WAIT-HELD mode
