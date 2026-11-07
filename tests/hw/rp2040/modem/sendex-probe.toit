// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import cellular.base.at as at
import expect show *
import io
import log
import uart

// Establish the installed NONOS firmware's exact CIPSENDEX binary semantics.
// The emergency filler is test-only and goes solely to the fixture echo peer.
main:
  port := uart.Port --tx=0 --rx=1 --baud-rate=115_200 --large-buffers
  session := at.Session port.in port.out
      --logger=(log.default.with-level log.INFO-LEVEL)
      --command-terminator=("\r\n".to-byte-array)
      --data-marker='>'
  session.add-ok-termination "SEND OK"
  session.add-error-termination "SEND FAIL"
  session.add-error-termination "FAIL"
  session.add-response-parser "+IPD" --prefix :: | reader/io.Reader |
    expect-equals ',' reader.read-byte
    at.parse-response (reader.read-bytes-up-to '\r')
  session.register-urc "+IPD" :: | parts | null
  session.add-response-parser "+CIPRECVDATA" --prefix :: | reader/io.Reader |
    expect-equals ',' reader.read-byte
    count := int.parse (reader.read-bytes-up-to ':').to-string
    expect (0 <= count <= 512)
    [reader.read-bytes count]
  completed := false
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
    payloads := [
      #[1, 0, 2, '\\', '0', 3, '\\', '\\', '0', '\\', 'x', 255],
      (ByteArray 512: it & 0xff),
      (ByteArray 1460 --initial='\\'),
    ]
    payloads.do: | payload/ByteArray |
      encoded := io.Buffer
      payload.do:
        if it == '\\': encoded.write-byte '\\'
        encoded.write-byte it
      encoded.write #[ '\\', '0' ]
      print "SENDEX probe sending $(payload.size) bytes as $(encoded.size) UART bytes"
      with-timeout --ms=10_000:
        session.send
          at.Command.set "+CIPSENDEX" --parameters=[0, 2048]
              --data=encoded.bytes
              --ok-before-data
              --timeout=(Duration --s=5)
        received := 0
        while received < payload.size:
          result := session.set "+CIPRECVDATA" [0, min 512 (payload.size - received)]
          bytes/ByteArray := result.responses.is-empty ? #[] : result.single.first
          expect-equals payload[received..received + bytes.size] bytes
          received += bytes.size
          if bytes.is-empty: sleep --ms=10
      print "SENDEX probe binary $(payload.size): PASS"
    session.set "+CIPCLOSE" [0]
    completed = true
    print "RP2040 ESP8285 sendex probe: PASS"
  finally:
    session.close
    if not completed:
      // A failed probe may leave the test modem waiting for data. Complete
      // that test payload before resetting; never use this in the driver.
      yield
      port.out.write (ByteArray 4096 --initial='A')
      port.out.write "\r\nAT+RST\r\n"
      port.out.flush
      sleep --ms=2000
      print "SENDEX probe emergency modem reset attempted"
    port.close
