// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import uart

import .wiring as wiring

/** ESP32 echo, burst, and RS485 direction peer for uart-rp2350.toit. */

INITIAL-BAUD ::= 115_200
TIMEOUT-MS ::= 10_000

main:
  direction := gpio.Pin wiring.ESP32-WEAK-OBSERVE-PIN --input
  direction-rises := [0]
  task --background::
    while true:
      direction.wait-for 1
      direction-rises[0]++
      direction.wait-for 0

  port := uart.Port
      --tx=wiring.ESP32-UART-TX-PIN
      --rx=wiring.ESP32-UART-RX-PIN
      --baud-rate=INITIAL-BAUD
  try:
    // Start the RP2350 only after this peer is ready to receive its greeting.
    run := gpio.Pin wiring.ESP32-RUN-PIN --output --open-drain --value=0
    try:
      sleep --ms=100
      run.set 1
    finally:
      run.close
    print "uart-esp32: peer ready; RP2350 reset released"
    first := true
    expected-rises := 0
    while true:
      // Allow the host to flash the RP2350 after starting this peer.
      line := read-line port --timeout-ms=(first ? 60_000 : TIMEOUT-MS)
      expected-rises++
      check-direction-pulse direction direction-rises expected-rises line
      first = false
      parts := line.split " "
      command := parts[0]
      if command == "HELLO" and parts.size == 2:
        send-line port "READY $parts[1]"
      else if command == "ECHO" and parts.size == 2:
        size := int.parse parts[1]
        send-line port "GO $size"
        payload := read-exactly port size
        expected-rises++
        check-direction-pulse direction direction-rises expected-rises "$(size)-byte payload"
        port.out.write payload
        port.out.flush
      else if command == "BAUD" and parts.size == 2:
        baud := int.parse parts[1]
        send-line port "SWITCH $baud"
        port.baud-rate = baud
        sleep --ms=20
        send-line port "READY $baud"
      else if command == "BURST" and parts.size == 2:
        size := int.parse parts[1]
        send-line port "GO $size"
        // Keep the acknowledgement and raw burst in separate RP2350 reads.
        sleep --ms=50
        port.out.write (payload size)
        port.out.flush
      else if command == "PING" and parts.size == 1:
        send-line port "PONG"
      else if command == "QUIT" and parts.size == 1:
        send-line port "BYE"
        print "uart-esp32: PASS paired UART and RS485 direction"
        return
      else:
        throw "invalid UART test command '$line'"
  finally:
    port.close

payload size/int -> ByteArray:
  result := ByteArray size
  size.repeat: | index |
    result[index] = (index * 73 + (index >> 3) + 29) & 0xff
  return result

send-line port/uart.Port line/string -> none:
  port.out.write "$line\n"
  port.out.flush

read-line port/uart.Port --timeout-ms/int=TIMEOUT-MS -> string:
  return with-timeout --ms=timeout-ms:
    bytes := #[]
    while true:
      byte := port.in.read-byte
      if byte == '\n': return bytes.to-string-non-throwing.trim
      bytes += #[byte]

read-exactly port/uart.Port size/int -> ByteArray:
  return with-timeout --ms=TIMEOUT-MS:
    result := #[]
    while result.size < size:
      chunk := port.in.read
      if not chunk: throw "UART closed at $result.size/$size bytes"
      result += chunk
    if result.size != size:
      throw "UART returned $result.size bytes, expected $size"
    return result

check-direction-pulse direction/gpio.Pin rises/List expected/int label/string -> none:
  with-timeout --ms=TIMEOUT-MS:
    while direction.get != 0 or rises[0] < expected:
      sleep (Duration --us=100)
  if rises[0] != expected:
    throw "RS485 direction produced $rises[0] pulses by $label, expected $expected"
