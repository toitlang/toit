// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import esp32.espnow

PMK ::= espnow.Key.from_string "pmk1234567890123"

main:
  service := espnow.Service.station --key=PMK
  service.add_peer
      espnow.BROADCAST_ADDRESS
      --channel=1
  task:: espnow_tx_task service
  task:: espnow_rx_task service

espnow_tx_task service/espnow.Service:
  count := 0
  while true:
    buffer := "hello $count"
    service.send
        buffer.to_byte_array
        --address=espnow.BROADCAST_ADDRESS
    print "Send datagram: \"$buffer\""

    count++
    sleep --ms=1000

espnow_rx_task service/espnow.Service:
  while true:
    datagram := service.receive
    if datagram:
      received_data := datagram.data.to_string
      print "Receive datagram from \"$datagram.address\", data: \"$received_data\""
    else:
      sleep --ms=1000
