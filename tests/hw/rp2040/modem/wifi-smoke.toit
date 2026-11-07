// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.
import cellular.base.at as at
import expect show *
import io
import log
import monitor show Channel
import system
import uart

// Start ../wifi-peer-esp32.toit on the helper first. Public test credentials.
// Uses the shared cellular AT session for commands and binary receive frames.
main:
  port := uart.Port --tx=0 --rx=1 --baud-rate=115_200
  session := at.Session port.in port.out
      --logger=(log.default.with-level log.INFO-LEVEL)
      --command-terminator=("\r\n".to-byte-array)
      --data-marker='>'
  incoming := Channel 16
  session.add-ok-termination "SEND OK"
  session.add-error-termination "SEND FAIL"
  session.add-response-parser "+IPD" --prefix :: |reader/io.Reader|
    expect-equals ',' reader.read-byte
    count := int.parse (reader.read-bytes-up-to ':').to-string
    if count <= 0 or count > 2048: throw "Unexpected modem frame length: $count"
    [reader.read-bytes count]
  session.register-urc "+IPD" :: |parts| incoming.send parts.first
  try:
    session.action ""
    session.action "E0"
    print (session.action "+GMR")
    session.set "+CWMODE_CUR" [1]
    session.set "+CWJAP_CUR" ["toit-rp2040-test", "pico-bringup-test"]
        --timeout=(Duration --s=30)
    print (session.action "+CIFSR")
    session.set "+CIPMUX" [0]
    session.set "+CIPMODE" [0]
    session.set "+CIPDINFO" [0]
    session.set "+CIPRECVMODE" [0]
    print "RP2040 cellular AT session/WiFi association: PASS"

    ["TCP", "UDP"].do: |protocol/string|
      session.set "+CIPSTART" [protocol, "200.200.200.1", 4242]
          --timeout=(Duration --s=10)
      32.repeat: |round|
        payload := ByteArray 512
        payload.size.repeat: payload[it] = (it * 37 + round * 13) & 0xff
        with-timeout --ms=5000:
          session.send
            at.Command.set "+CIPSEND" --parameters=[payload.size] --data=payload --ok-before-data
          system.process-stats --gc
          received := 0
          while received < payload.size:
            data/ByteArray := incoming.receive
            if data.size > payload.size - received: throw "Unexpected echo length"
            if protocol == "UDP": expect-equals payload.size data.size
            expect-equals payload[received..received + data.size] data
            received += data.size
      session.action "+CIPCLOSE"
      print "RP2040 ESP8285 $protocol echo/GC: PASS (32 x 512 bytes)"
  finally:
    session.close
    port.close
  print "RP2040 ESP8285 WiFi smoke: PASS"
