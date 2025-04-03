// Copyright (C) 2025 Toit contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import esp32.espnow
import esp32
import expect show *
import gpio
import uart

import .test
import .variants

/**
Tests the espnow functionality.

This test must be run without WiFi. (In theory it's
  possible to run with WiFi, but then the channel needs to be
  set to the same channel as the WiFi network.)

On Jaguar use:
  `jag container install -D jag.disabled -D jag.timeout=1m espnow espnow2_board1.toit`

Run `espnow2_board1.toit` on board1.
Once that one is running, run `espnow2_board2.toit` on board2.

Connect as described in the variants file.
*/

PMK ::= espnow.Key.from-string Variant.CURRENT.espnow-password
RX ::= Variant.CURRENT.board-connection-pin1
TX ::= Variant.CURRENT.board-connection-pin2
BAUD-RATE ::= 115200

END-TOKEN ::= "<END>"

TEST-DATA ::= [
  "The Iron Rule: Treat others less powerful than you however you like.",
  "The Silver Rule: Treat others as you'd like to be treated.",
  "The Golden Rule: Treat others as they'd like to be treated.",
  "― Dennis E. Taylor, Heaven's River",
  END-TOKEN
]

CHANNEL ::= Variant.CURRENT.espnow-channel

main-board1:
  run-test: test-board1

test-board1:
  service ::= espnow.Service.station --key=PMK --channel=CHANNEL

  port := uart.Port --rx=(gpio.Pin RX) --tx=null --baud-rate=BAUD-RATE
  other-bytes := port.in.read-bytes 6  // Read MAC address of other board.
  other-address := espnow.Address other-bytes
  print "Other address: $other-address"

  data := service.receive
  print data.address
  service.add-peer other-address

  TEST-DATA.do:
    service.send
        it.to-byte-array
        --address=other-address
    print it
  ok := service.receive
  expect-equals #['o', 'k'] ok.data
  print "Received: $ok"

main-board2:
  run-test: test-board2

test-board2:
  port := uart.Port --rx=null --tx=(gpio.Pin TX) --baud-rate=BAUD-RATE
  port.out.write --flush esp32.mac-address

  service ::= espnow.Service.station --key=PMK --channel=CHANNEL

  service.add-peer espnow.BROADCAST-ADDRESS
  service.send --address=espnow.BROADCAST-ADDRESS #['h', 'i']

  print "Listening for messages."
  with-timeout --ms=10_000:
    received := []
    other-address/espnow.Address? := null
    while true:
      datagram := service.receive
      message := datagram.data.to-string
      received.add message
      if message == END-TOKEN: break
      print message
      other-address = datagram.address

    expect-equals TEST-DATA received
    service.add-peer other-address
    service.send --address=other-address #['o', 'k']

