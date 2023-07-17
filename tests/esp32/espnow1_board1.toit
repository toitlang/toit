// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests the espnow functionality.

This test must be run without WiFi. (In theory it's
  possible to run with WiFi, but then the channel needs to be
  set to the same channel as the WiFi network.)

On Jaguar use:
  `jag container install -D jag.disabled -D jag.timeout=1m espnow espnow1_board1.toit`

Run `espnow1_board1.toit` on board1.
Once that one is running, run `espnow1_board2.toit` on board2.

*/

import esp32.espnow
import expect show *
import .espnow1_shared

main:
  service ::= espnow.Service.station --key=PMK

  service.add_peer
      espnow.BROADCAST_ADDRESS
      --channel=CHANNEL

  print "Listening for messages."
  with_timeout --ms=10_000:
    received := []
    while true:
      datagram := service.receive
      if datagram:
        message := datagram.data.to_string
        received.add message
        if message == END_TOKEN: break
        print message
      else:
        sleep --ms=10

    expect_equals TEST_DATA received
