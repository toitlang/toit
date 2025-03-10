// Copyright (C) 2025 Toit contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests some WiFi functionality

Uses the UART to communicate between the two devices.
*/

import expect show *
import gpio
import monitor
import net
import net.wifi
import uart

import .test
import .variants

RX ::= Variant.CURRENT.board-connection-pin1
TX ::= Variant.CURRENT.board-connection-pin2
BAUD-RATE ::= 115200

SSID ::= "test-wifi-scan"

PORT ::= 7017

MAX-RETRIES ::= 4
RETRY-WAIT ::= 300

// TODO(florian): don't use hardcoded IP.
SOFTAP-ADDRESS ::= "200.200.200.1"

class Config:
  is-encrypted/bool
  channel/int

  constructor --.is-encrypted --.channel:

  name -> string:
    return "test-$(is-encrypted ? "encrypted" : "unencrypted")-$(channel)"

  ssid -> string:
    return "$SSID-$channel-$(is-encrypted ? "X" : "")"

  password -> string:
    return is-encrypted ? "password" : ""

CONFIGS-TO-TEST ::= [
  Config --is-encrypted=false --channel=1,
  // 11 is the max channel for "world safe mode".
  // In Japan, the max channel would go up to 14, but we can't test that
  Config --is-encrypted=false --channel=11,
  Config --is-encrypted=true --channel=1,
]


main-board1:
  run-test: test-board1

contains-ssid access-points/List ssid/string:
  return access-points.any: | ap/wifi.AccessPoint | ap.ssid == ssid

test-board1:
  tx := gpio.Pin TX
  rx := gpio.Pin RX
  port := uart.Port --tx=tx --rx=rx --baud-rate=BAUD-RATE
  CONFIGS-TO-TEST.do: | config/Config |
    // Wait for board 2 to be ready.
    port.in.read

    scanned := wifi.scan #[config.channel]
    expect (contains-ssid scanned config.ssid)
    other-channel := config.channel == 1 ? 5 : 1
    scanned = wifi.scan #[other-channel]
    expect-not (contains-ssid scanned config.ssid)

    // Connect to the other board.
    network/net.Client? := null
    for i := 0; i < MAX-RETRIES; i++:
      catch --trace:
        network = wifi.open --ssid=config.ssid --password=config.password
        break
      if i == MAX-RETRIES - 1:
        throw "Failed to connect"
      sleep --ms=RETRY-WAIT
    print "Connected"
    socket := network.tcp-connect SOFTAP-ADDRESS PORT
    socket.out.write "ok" --flush
    socket.close
    network.close

main-board2:
  run-test: test-board2

test-board2:
  tx := gpio.Pin TX
  rx := gpio.Pin RX
  port := uart.Port --tx=tx --rx=rx --baud-rate=BAUD-RATE
  CONFIGS-TO-TEST.do: | config/Config |
    network-ap := wifi.establish
        --name=config.name
        --ssid=config.ssid
        --password=config.password
        --channel=config.channel
    print "established"
    server-socket := network-ap.tcp-listen PORT
    port.out.write "x" --flush  // Ready to receive.
    socket := server-socket.accept
    received := socket.in.read
    expect-equals #['o', 'k'] received
    socket.close
    server-socket.close
    network-ap.close

