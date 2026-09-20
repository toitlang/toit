// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import uart

import .wiring as wiring

/** ESP32 echo and burst peer for uart-rp2350.toit. Start this side first. */

INITIAL-BAUD ::= 115_200
TIMEOUT-MS ::= 10_000

main:
  port := uart.Port
      --tx=wiring.ESP32-UART-TX-PIN
      --rx=wiring.ESP32-UART-RX-PIN
      --baud-rate=INITIAL-BAUD
  try:
    first := true
    while true:
      // Allow the host to flash the RP2350 after starting this peer.
      line := read-line port --timeout-ms=(first ? 60_000 : TIMEOUT-MS)
      first = false
      parts := line.split " "
      command := parts[0]
      if command == "HELLO" and parts.size == 2:
        send-line port "READY $parts[1]"
      else if command == "ECHO" and parts.size == 2:
        size := int.parse parts[1]
        send-line port "GO $size"
        payload := read-exactly port size
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
