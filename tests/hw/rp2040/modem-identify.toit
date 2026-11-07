// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.
import uart

// W-2023 only. Disconnect the helper's TX jumper from GP1 before running.
// These commands identify the onboard modem without changing its settings.
main:
  port := uart.Port --tx=0 --rx=1 --baud-rate=115_200
  try:
    // Discard any startup chatter before sending a command.
    catch:
      with-timeout --ms=250:
        while port.in.read: null
    ["AT", "AT+GMR"].do: |command/string|
      print "MODEM > $command"
      port.out.write "$command\r\n"
      response := ""
      with-timeout --ms=3000:
        while not response.contains "\r\nOK\r\n":
          data := port.in.read
          if not data: throw "Modem UART closed"
          response += data.to-string-non-throwing
          if response.size > 4096: throw "Unexpected modem response"
          if response.contains "\r\nERROR\r\n": throw response
      print response.trim
    print "RP2040 ESP8285 identification: PASS"
  finally:
    port.close
