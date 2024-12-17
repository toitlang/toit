// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
See 'espnow1_board1.toit'
*/

import esp32.espnow

import .espnow1-shared
import .test

main:
  run-test: test-espnow

test-espnow:
  service ::= espnow.Service.station --key=PMK --channel=CHANNEL

  service.add-peer espnow.BROADCAST-ADDRESS

  TEST-DATA.do:
    service.send
        it.to-byte-array
        --address=espnow.BROADCAST-ADDRESS
    print it
