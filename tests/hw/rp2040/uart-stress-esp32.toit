// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import uart
import ..rp2350.uart-esp32 as shared

// Verified connection: ESP32 GPIO4 -> GP17, GPIO34 <- GP16. No RUN or DE use.
main:
  port := uart.Port --tx=4 --rx=34 --baud-rate=115_200 --large-buffers
  try:
    print "uart-stress-esp32: READY"
    while true:
      line := shared.read-line port --timeout-ms=180_000
      parts := line.split " "
      command := parts[0]
      if command == "HELLO" and parts.size == 2:
        shared.send-line port "READY $parts[1]"
      else if command == "ECHO" and parts.size == 2:
        size := int.parse parts[1]
        shared.send-line port "GO $size"
        port.out.write (shared.read-exactly port size)
        port.out.flush
      else if command == "BAUD" and parts.size == 2:
        baud := int.parse parts[1]
        shared.send-line port "SWITCH $baud"
        port.baud-rate = baud
        sleep --ms=20
        shared.send-line port "READY $baud"
      else if command == "BURST" and parts.size == 2:
        size := int.parse parts[1]
        shared.send-line port "GO $size"
        sleep --ms=50
        port.out.write (shared.payload size)
        port.out.flush
      else if command == "PING":
        shared.send-line port "PONG"
      else if command == "QUIT":
        shared.send-line port "BYE"
        print "uart-stress-esp32: PASS"
        return
      else:
        throw "Invalid UART test command: $line"
  finally:
    port.close
