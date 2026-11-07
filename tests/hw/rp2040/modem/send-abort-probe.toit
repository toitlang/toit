// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *
import io
import uart

// Characterize the installed NONOS modem, independently of the AT session.
// All payloads go to the isolated fixture echo server. Emergency filler is
// test cleanup only, never a proposed network-driver recovery mechanism.
main:
  port := uart.Port --tx=0 --rx=1 --baud-rate=115_200 --large-buffers
  probe := Probe port
  completed := false
  try:
    with-timeout --ms=100_000:
      probe.setup
      ["TCP", "UDP"].do: | protocol/string |
        probe.command "AT+CIPSTART=0,\"$protocol\",\"200.200.200.1\",4242"
        [0, 7, 63, 64].do: | count/int |
          probe.begin-send 65
          if count > 0: probe.write (ByteArray count --initial='A')
          sleep --ms=50
          probe.write "+++"
          response := probe.capture 500
          print "$protocol interrupted after $count: $response"
          expect (response.contains "SEND Canceled")
          expect (not response.contains "SEND OK")
          expect (not response.contains "+IPD")
          probe.command "AT"
          if protocol == "TCP":
            response = probe.command "AT+CIPRECVLEN?"
            expect (response.contains "+CIPRECVLEN:0,0,0,0,0")
          // A subsequent successful echo checks that abort did not leak the
          // partial payload into the TCP stream or a truncated UDP datagram.
          probe.begin-send 4
          probe.write "TEST"
          response = probe.capture 500
          expect (response.contains "SEND OK")
          if protocol == "TCP":
            response = probe.command "AT+CIPRECVDATA=0,512"
            expect (response.contains "+CIPRECVDATA,4:TEST")
          else:
            expect (response.contains "+IPD,0,4:TEST")
          print "$protocol abort and reuse after $count: PASS"
        probe.command "AT+CIPCLOSE=0"
      probe.characterize-framing
      print "RP2040 ESP8285 send abort probe: PASS"
      completed = true
  finally:
    if not completed:
      probe.write (ByteArray 4096 --initial='A')
      probe.write "\r\nAT+RST\r\n"
      sleep --ms=2000
      print "Send abort probe emergency reset attempted"
    port.close

class Probe:
  port_/uart.Port
  constructor .port_:

  write data/io.Data:
    port_.out.write data
    port_.out.flush

  capture ms/int -> string:
    buffer := io.Buffer
    error := catch:
      with-timeout --ms=ms:
        while true: buffer.write-byte port_.in.read-byte
    if error and error != "DEADLINE_EXCEEDED": throw error
    return buffer.bytes.to-string-non-throwing

  command text/string -> string:
    write "$text\r\n"
    response := io.Buffer
    with-timeout --ms=30_000:
      while true:
        line := port_.in.read-bytes-up-to '\n'
        response.write line
        response.write-byte '\n'
        if line.to-string-non-throwing == "OK\r": break
        expect (line.to-string-non-throwing != "ERROR\r")
    return response.bytes.to-string-non-throwing

  begin-send length/int --extended=false:
    name := extended ? "CIPSENDEX" : "CIPSEND"
    write "AT+$name=0,$length\r\n"
    with-timeout --ms=5000:
      response := port_.in.read-bytes-up-to '>'
      expect (response.to-string-non-throwing.contains "OK")

  characterize-framing:
    command "AT+CIPSTART=0,\"TCP\",\"200.200.200.1\",4242"
    begin-send 3
    write "+++"
    response := capture 500
    print "Literal three-plus payload: $response"
    // This assertion characterizes a modem defect, not correct behavior.
    expect (response.contains "SEND Canceled")
    begin-send 3
    write "+"
    sleep --ms=50
    write "++"
    response = capture 500
    expect (response.contains "SEND OK")
    response = command "AT+CIPRECVDATA=0,512"
    expect (response.contains "+CIPRECVDATA,3:+++")
    print "Split three-plus payload: PASS"

    begin-send 2048 --extended
    write #[ 'A', '\\' ]
    sleep --ms=50
    write #[ '\\', 'B', '\\', '0' ]
    response = capture 500
    expect (response.contains "SEND OK")
    response = command "AT+CIPRECVDATA=0,512"
    print "Split CIPSENDEX escape: $response"
    // The installed parser loses escape state across UART receive batches.
    expect (response.contains "+CIPRECVDATA,4:A\\\\B")
    command "AT+CIPCLOSE=0"

  setup:
    command "AT"
    command "ATE0"
    print (command "AT+GMR")
    command "AT+CWMODE_CUR=1"
    command "AT+CWJAP_CUR=\"toit-rp2040-test\",\"pico-bringup-test\""
    write "AT+CIPCLOSE=5\r\n"
    capture 500
    command "AT+CIPMUX=0"
    command "AT+CIPMODE=0"
    command "AT+CIPMUX=1"
    command "AT+CIPDINFO=0"
    command "AT+CIPRECVMODE=1"
