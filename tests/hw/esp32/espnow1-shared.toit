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

CONFIGURATIONS ::= [
  [null, null],
  [espnow.RATE-1M-L, espnow.MODE-11G],
  [espnow.RATE-LORA-250K, espnow.MODE-LR],
  [espnow.RATE-9M, espnow.MODE-11G],
  [espnow.RATE-MCS7-SGI, espnow.MODE-HT20],
]

main-board1:
  run-test: test-board1

test-board1:
  service ::= espnow.Service --key=PMK --channel=CHANNEL

  service.add-peer espnow.BROADCAST-ADDRESS

  print "Listening for messages."
  CONFIGURATIONS.size.repeat:
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
  service ::= espnow.Service --key=PMK --channel=CHANNEL

  CONFIGURATIONS.do: | config/List |
    sleep --ms=200
    rate := config[0]
    mode := config[1]

    service.add-peer espnow.BROADCAST-ADDRESS
        --rate=rate
        --mode=mode

    TEST-DATA.do:
      service.send
          it.to-byte-array
          --address=espnow.BROADCAST-ADDRESS
      print it

    service.remove-peer espnow.BROADCAST-ADDRESS
