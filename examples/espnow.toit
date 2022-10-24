// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import esp32.espnow

service ::= espnow.Service --pmk="pmk1234567890123".to_byte_array

main:
  service.add_peer
      espnow.BROADCAST_MAC
      --channel=1

  task:: espnow_tx_task
  task:: espnow_rx_task

espnow_tx_task:
  count := 0
  while true:
    buffer := "hello $count"    
    ret := service.send
        buffer.to_byte_array
        --address=espnow.BROADCAST_MAC
    if ret < 0:
      print "Failed to send datagram result is $ret"
    else:
      print "Send datagram: \"$buffer\""

    count++
    sleep --ms=1000

espnow_rx_task:
  while true:
    datagram := service.receive
    if datagram:
      recv_data := datagram.data.to_string
      print "Receive datagram from \"$datagram.address\", data: \"$recv_data\""
    else:
      sleep --ms=1000
