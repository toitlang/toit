// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.service.client as service
import system

main:
  client := service.Client
  client.open --timeout=(Duration --s=10)
  try:
    2.repeat: | mode/int |
      data := #[2, 1, 6, 10, 0xff, 0xff, 0xff, 't', 'o', 'i', 't', 'a', 'd', mode]
      response := mode == 1 ? #[8, 9, 'T', 'o', 'i', 't', 'A', 'd', 'v'] : #[]
      client.with-advertising data --scan-response=response --scannable=(mode == 1):
        print "ADVERTISING_APP READY mode=$mode"
        // Changing source data after enable must not change controller data.
        data.fill 0
        system.process-stats --gc
        sleep --ms=15_000
      print "ADVERTISING_APP STOPPED mode=$mode"
      sleep --ms=3_000
    print "ADVERTISING_APP COMPLETE"
  finally:
    client.close
