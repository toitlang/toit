// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import cellular.base.at as at
import log
import uart

// Retained diagnostic for NONOS DNS settings and negative lookup latency.
main:
  port := uart.Port --tx=0 --rx=1 --baud-rate=115_200 --large-buffers
  session := at.Session port.in port.out
      --logger=(log.default.with-level log.DEBUG-LEVEL)
      --command-terminator=("\r\n".to-byte-array)
  try:
    session.action ""
    session.action "E0"
    session.set "+CWMODE_CUR" [1]
    session.set "+CWJAP_CUR" ["toit-rp2040-test", "pico-bringup-test"]
        --timeout=(Duration --s=30)
    session.read "+CIPDNS_CUR"
    session.set "+CIPDNS_CUR" [1, "200.200.200.1"]
    session.read "+CIPDNS_CUR"
    ["echo.rp2040.test", "absent.rp2040.test", "burst.rp2040.test"].do: | name |
      start := Time.monotonic-us
      error := catch:
        result := session.set "+CIPDOMAIN" [name] --timeout=(Duration --s=60)
        print "DNS reply: $result.responses"
      print "DNS $name: $(error or "OK") after $((Time.monotonic-us - start) / 1000) ms"
    print "RP2040 ESP8285 DNS probe: DONE"
  finally:
    session.close
    port.close
