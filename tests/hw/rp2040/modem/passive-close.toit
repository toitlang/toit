// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import cellular.base.at as at
import expect show *
import io
import log
import system
import uart

// Measures whether NONOS retains passive receive data after a CLOSED notice.
main:
  port := uart.Port --tx=0 --rx=1 --baud-rate=115_200 --large-buffers
  session := at.Session port.in port.out
      --logger=(log.default.with-level log.INFO-LEVEL)
      --command-terminator=("\r\n".to-byte-array)
      --command-delay=(Duration --ms=0)
  total := 0
  closed := false
  session.on-unhandled-line = :: | line/string |
    if line == "0,CLOSED":
      print "TCP CLOSED notice after $total consumed bytes"
      closed = true
      true
    else:
      false
  session.add-response-parser "+IPD" --prefix :: | reader/io.Reader |
    expect-equals ',' reader.read-byte
    at.parse-response (reader.read-bytes-up-to '\r')
  session.register-urc "+IPD" :: | parts | null
  session.add-response-parser "+CIPRECVDATA" --prefix :: | reader/io.Reader |
    expect-equals ',' reader.read-byte
    count := int.parse (reader.read-bytes-up-to ':').to-string
    expect (0 <= count <= 512)
    [reader.read-bytes count]
  try:
    session.action ""
    session.action "E0"
    session.set "+CWMODE_CUR" [1]
    session.set "+CWJAP_CUR" ["toit-rp2040-test", "pico-bringup-test"]
        --timeout=(Duration --s=30)
    session.set "+CIPCLOSE" [5] --no-check
    session.set "+CIPMUX" [0]
    session.set "+CIPMODE" [0]
    session.set "+CIPMUX" [1]
    session.set "+CIPDINFO" [1]
    session.set "+CIPRECVMODE" [1]
    session.set "+CIPSTART" [0, "TCP", "200.200.200.1", 4243]
        --timeout=(Duration --s=15)
    sleep --ms=1000
    with-timeout --ms=60_000:
      while true:
        bytes/ByteArray? := null
        error := catch:
          bytes = (session.set "+CIPRECVDATA" [0, 512]).single.first
        if error:
          print "Read ended: $error"
          break
        if not bytes.is-empty:
          expect-equals (ByteArray bytes.size: ((total + it) * 31 + 19) & 0xff) bytes
          total += bytes.size
          system.process-stats --gc
        else if closed:
          break
        else:
          sleep --ms=5
      result := session.read "+CIPRECVLEN"
      print "TCP total=$total, pending=$result.responses, closed=$closed"
    session.set "+CIPCLOSE" [0] --no-check
    print "RP2040 ESP8285 passive close probe: DONE"
  finally:
    session.close
    port.close
