// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import cellular.base.at as at
import expect show *
import io
import log
import system
import uart

// Uses only the W-2023 onboard modem UART and the helper's existing Wi-Fi AP.
main:
  port := uart.Port --tx=0 --rx=1 --baud-rate=115_200 --large-buffers
  session := at.Session port.in port.out
      --logger=(log.default.with-level log.INFO-LEVEL)
      --command-terminator=("\r\n".to-byte-array)
      --data-marker='>'
  notifications := 0
  session.add-ok-termination "SEND OK"
  session.add-error-termination "SEND FAIL"
  session.add-response-parser "+IPD" --prefix :: |reader/io.Reader|
    expect-equals ',' reader.read-byte
    at.parse-response (reader.read-bytes-up-to '\r')
  session.register-urc "+IPD" :: |parts|
    expect-equals 0 parts[0]
    expect (0 < parts[1] <= 65535)
    notifications++
  session.add-response-parser "+CIPRECVDATA" --prefix :: |reader/io.Reader|
    // NONOS AT 1.7 uses a comma before the length and colon before payload.
    expect-equals ',' reader.read-byte
    count := int.parse (reader.read-bytes-up-to ':').to-string
    expect (0 <= count <= 257)
    [reader.read-bytes count]
  try:
    session.action ""
    session.action "E0"
    print (session.action "+GMR")
    session.set "+CWMODE_CUR" [1]
    session.set "+CWJAP_CUR" ["toit-rp2040-test", "pico-bringup-test"]
        --timeout=(Duration --s=30)
    session.set "+CIPCLOSE" [5] --no-check
    session.set "+CIPMUX" [0]
    session.set "+CIPMODE" [0]
    session.set "+CIPMUX" [1]
    session.set "+CIPDINFO" [0]
    session.set "+CIPRECVMODE" [1]
    session.set "+CIPSTART" [0, "TCP", "200.200.200.1", 4242]
        --timeout=(Duration --s=10)
    8.repeat: |round/int|
      payload := ByteArray 1537: (it * 37 + round * 13) & 0xff
      with-timeout --ms=5000:
        session.send
          at.Command.set "+CIPSEND" --parameters=[0, payload.size]
              --data=payload
              --ok-before-data
        // Leave data in the modem while the VM collects and other tasks run.
        system.process-stats --gc
        sleep --ms=100
        received := 0
        while received < payload.size:
          response := session.set "+CIPRECVDATA" [0, min 257 (payload.size - received)]
          bytes/ByteArray := response.single.first
          expect (bytes.size <= payload.size - received)
          expect-equals payload[received..received + bytes.size] bytes
          received += bytes.size
          if bytes.is-empty: sleep --ms=5
      print "ESP8285 passive TCP round=$round bytes=$(payload.size) PASS"
    expect (notifications > 0)
    print (session.read "+CIPRECVLEN")
    session.set "+CIPCLOSE" [0]
    session.set "+CIPRECVMODE" [0]
    session.set "+CIPMUX" [0]
    print "RP2040 ESP8285 passive TCP: PASS"
  finally:
    session.close
    port.close
