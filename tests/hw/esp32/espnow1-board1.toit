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

import .espnow1-shared
import .test

main:
  run-test: test-espnow

test-espnow:
  service ::= espnow.Service.station --key=PMK --channel=CHANNEL

  service.add-peer espnow.BROADCAST-ADDRESS

  print "Listening for messages."
  with-timeout --ms=10_000:
    received := []
    while true:
      datagram := service.receive
      message := datagram.data.to-string
      received.add message
      if message == END-TOKEN: break
      print message

    expect-equals TEST-DATA received
