// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

/**
An example of using ESP-NOW to send and receive data between ESP32 devices.

This program broadcasts a message every second and prints any received messages.
Running this program on multiple ESP32 devices will result in them printing
  each other's messages.
*/

import esp32.espnow

PMK ::= espnow.Key.from_string "pmk1234567890123"

main:
  service := espnow.Service.station --key=PMK
  service.add_peer
      espnow.BROADCAST_ADDRESS
      --channel=1
  task:: send_task service
  task:: receive_task service

send_task service/espnow.Service:
  count := 0
  while true:
    buffer := "hello $count"
    service.send
        buffer.to_byte_array
        --address=espnow.BROADCAST_ADDRESS
    print "Send datagram: \"$buffer\""

    count++
    sleep --ms=1_000

receive_task service/espnow.Service:
  while true:
    datagram := service.receive
    received_data := datagram.data.to_string
    print "Receive datagram from \"$datagram.address\", data: \"$received_data\""
