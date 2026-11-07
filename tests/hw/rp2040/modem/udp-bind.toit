// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import cellular.base.at as at
import log
import uart

// Diagnostic matrix for NONOS AT's UDP local-port and wildcard-host rules.
main:
  port := uart.Port --tx=0 --rx=1 --baud-rate=115_200 --large-buffers
  session := at.Session port.in port.out
      --logger=(log.default.with-level log.INFO-LEVEL)
      --command-terminator=("\r\n".to-byte-array)
  try:
    session.action ""
    session.action "E0"
    session.set "+CWMODE_CUR" [1]
    session.set "+CWJAP_CUR" ["toit-rp2040-test", "pico-bringup-test"]
        --timeout=(Duration --s=30)
    session.set "+CIPCLOSE" [5] --no-check
    session.set "+CIPMUX" [1]
    cases := [
      [0, "UDP", "0.0.0.0", 1, 0, 2],
      [0, "UDP", "0.0.0.0", 1, 49152, 2],
      [0, "UDP", "200.200.200.1", 4242, 0, 2],
      [0, "UDP", "200.200.200.1", 4242, 49152, 2],
      [0, "UDP", "0.0.0.0", 1],
    ]
    cases.do: | args |
      result := catch: session.set "+CIPSTART" args
      print "UDP bind $args: $(result or "OK")"
      print (session.action "+CIPSTATUS")
      session.set "+CIPCLOSE" [0] --no-check
    print "RP2040 ESP8285 UDP bind probe: DONE"
  finally:
    session.close
    port.close
