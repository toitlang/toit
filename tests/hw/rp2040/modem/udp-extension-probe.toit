// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import cellular.base.at as at
import io
import log
import uart

// Acceptance for the experimental +TOITUDP AT extension. Run with the ordinary
// Wi-Fi helper, including its UDP boundary fixture on ports 4246 and 4247.
main:
  port := uart.Port --tx=0 --rx=1 --baud-rate=115_200 --large-buffers
  session := at.Session port.in port.out
      --logger=(log.default.with-level log.INFO-LEVEL)
      --command-terminator=("\r\n".to-byte-array)
      --data-marker='>'
  session.add-ok-termination "SEND OK"
  session.add-error-termination "SEND FAIL"
  session.add-error-termination "SEND Canceled"
  session.add-response-parser "+IPD" --prefix :: | reader/io.Reader |
    reader.read-bytes-up-to '\r'
    []
  session.register-urc "+IPD" :: | parts | null
  completed := false
  try:
    session.action ""
    session.action "E0"
    print (session.action "+GMR")
    capability := (session.read "+TOITUDP").single
    check (capability == [1, 1460] or capability == [2, 1460])
    session.add-response-parser "+TOITUDP" --prefix :: | reader/io.Reader |
      check (reader.read-byte == ':')
      first := reader.read-byte
      if first == '-':
        status := -(int.parse (reader.read-bytes-up-to '\r').to-string)
        check (status == -1 or status == -2)
        [status]
      else:
        token := io.Buffer
        token.write-byte first
        token.write (reader.read-bytes-up-to ',')
        count := int.parse token.bytes.to-string
        check (0 <= count <= 1460)
        address := (reader.read-bytes-up-to ',').to-string
        remote-port := int.parse (reader.read-bytes-up-to ',').to-string
        [count, address, remote-port, reader.read-bytes count]
    session.set "+SYSSTORE" [0]
    session.set "+CWMODE" [1]
    session.set "+CWJAP" ["toit-rp2040-test", "pico-bringup-test"]
        --timeout=(Duration --s=30)
    if (session.read "+CIPMUX").single.first == 0:
      session.action "+CIPCLOSE" --no-check
    else:
      session.set "+CIPCLOSE" [5] --no-check
    session.set "+CIPMUX" [0]
    session.set "+CIPMODE" [0]
    session.set "+CIPRECVMODE" [1]
    2.repeat: | cycle/int |
      session.set "+CIPSTART" ["UDP", "200.200.200.1", 4246, 4248, 2]
      check ((session.set "+TOITUDP" [0]).single == [-1])
      // Repeat on the same socket after draining it: the original AT core
      // does not see our receives and may retain its notification state.
      2.repeat: | burst/int |
        with-timeout --ms=10_000:
          session.send
            at.Command.set "+CIPSEND" --parameters=[5]
                --data=("burst".to-byte-array)
                --ok-before-data
          // Six packets fit the candidate's six-entry UDP mailbox. Wait for all
          // nonempty bytes, so immediate reads cannot hide a queue-boundary bug.
          while true:
            pending := (session.read "+CIPRECVLEN").single.first
            if pending == 4840: break
            check (0 <= pending < 4840)
            sleep --ms=10
          sizes := [1009, 907, 0, 1460, 1461, 3]
          sizes.size.repeat: | index/int |
            size/int := sizes[index]
            packet := (session.set "+TOITUDP" [0]).single
            if size > 1460:
              check (packet == [-2])
            else:
              check (packet.size == 4)
              check (packet[0] == size)
              check (packet[1] == "\"200.200.200.1\"")
              check (packet[2] == (index % 2 == 0 ? 4246 : 4247))
              check (packet[3] == (ByteArray size: (it * 37 + size) & 0xff))
            print "TOITUDP packet $index size=$size: PASS"
          check ((session.set "+TOITUDP" [0]).single == [-1])
        print "TOITUDP cycle $cycle burst $burst: PASS"
      session.action "+CIPCLOSE"
      print "TOITUDP cycle $cycle: PASS"
    check (port.errors == 0)
    completed = true
  finally:
    try:
      print "TOITUDP Pico UART errors=$(port.errors)"
      if not completed and not session.is-closed:
        error := catch:
          with-timeout --ms=3000: session.action "+RST"
        print "TOITUDP reset: $(error or "acknowledged")"
    finally:
      try:
        session.close
      finally:
        port.close
  print "RP2040 ESP8285 UDP extension: PASS"

check condition/bool:
  if not condition: throw "TOITUDP_CHECK_FAILED"
