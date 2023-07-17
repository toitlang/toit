// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
See 'espnow1_board1.toit'
*/

import esp32.espnow
import .espnow1_shared

main:
  service ::= espnow.Service.station --key=PMK

  service.add_peer
      espnow.BROADCAST_ADDRESS
      --channel=CHANNEL

  TEST_DATA.do:
    service.send
        it.to_byte_array
        --address=espnow.BROADCAST_ADDRESS
    print it
    sleep --ms=20
