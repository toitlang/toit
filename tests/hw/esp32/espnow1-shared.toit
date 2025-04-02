// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import esp32.espnow
import expect show *

import .test
import .variants

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

PMK ::= espnow.Key.from-string Variant.CURRENT.espnow-password

END-TOKEN ::= "<END>"

TEST-DATA ::= [
  "In my younger and more vulnerable years",
  "my father gave me some advice",
  "that I've been turning over in my mind ever since.",
  "\"Whenever you feel like criticizing any one,\"",
  "he told me,",
  "\"just remember that all the people in this world",
  "haven't had the advantages that you've had.\"",
  "-- F. Scott Fitzgerald",
  "The Great Gatsby",
  END-TOKEN
]

CHANNEL ::= Variant.CURRENT.espnow-channel

main-board1:
  run-test: test-board1

test-board1:
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

main-board2:
  run-test: test-board2

test-board2:
  service ::= espnow.Service.station --key=PMK --channel=CHANNEL

  service.add-peer espnow.BROADCAST-ADDRESS

  TEST-DATA.do:
    service.send
        it.to-byte-array
        --address=espnow.BROADCAST-ADDRESS
    print it
