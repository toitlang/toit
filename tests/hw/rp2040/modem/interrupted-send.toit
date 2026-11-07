// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import cellular.modules.espressif.esp8285 show Esp8285
import expect show *
import io
import log
import monitor
import uart

// Interrupt an actual modem data prompt at a known payload boundary. The
// explicit terminator below is test cleanup, not a general resynchronization
// algorithm: it relies on knowing exactly which bytes reached the modem.
class PausedWriter extends io.Writer:
  output/io.Writer
  entered ::= monitor.Latch
  resume ::= monitor.Latch
  armed := false
  interrupted := false
  count := 0

  constructor .output:

  try-write_ data/io.Data from/int to/int -> int:
    if armed and to - from == 67:
      armed = false
      count += output.write data from (from + 7)
      interrupted = true
      entered.set true
      resume.get
      return 7
    written := output.write data from to
    count += written
    return written

main:
  port := uart.Port --tx=0 --rx=1 --baud-rate=115_200 --large-buffers
  try:
    [false, true].do: | deadline/bool |
      test-interruption port --deadline=deadline
    expect-equals 0 port.errors
    print "RP2040 ESP8285 interrupted send: PASS"
  finally:
    port.close

test-interruption port/uart.Port --deadline/bool:
  writer := PausedWriter port.out
  network := Esp8285 port.in writer --logger=(log.default.with-level log.ERROR-LEVEL)
  try:
    network.connect "toit-rp2040-test" "pico-bringup-test"
    socket := network.tcp-connect "200.200.200.1" 4242
    ended := monitor.Latch
    reader-ended := monitor.Latch
    task::
      data := null
      error := catch: data = socket.in.read
      reader-ended.set (error or data)
    writer.armed = true
    worker := task::
      try:
        error := catch:
          with-timeout --ms=(deadline ? 1000 : 10_000):
            socket.out.write (ByteArray 65 --initial=0xa5)
        if deadline: expect (error != null)
      finally:
        critical-do: ended.set true
    with-timeout --ms=5000:
      writer.entered.get
      if not deadline: worker.cancel
      expect ended.get
      expect network.is-closed
      result := reader-ended.get
      expect (result == null or result == "NETWORK_CLOSED")
      count := writer.count
      expect-throw "NETWORK_CLOSED": network.resolve "late.test"
      expect-equals count writer.count
    socket.close
  finally:
    network.close
    // Session.close has joined its receive task; the caller owns the UART.
    // Complete this fixture's known frame even when an assertion fails.
    if writer.interrupted:
      with-timeout --ms=5000:
        port.out.write "\\0"
        while true:
          line := port.in.read-line
          if line == "SEND OK\r" or line == "SEND OK": break
  restored := Esp8285 port.in port.out --logger=(log.default.with-level log.ERROR-LEVEL)
  try:
    restored.connect "toit-rp2040-test" "pico-bringup-test"
    socket := restored.tcp-connect "200.200.200.1" 4242
    try:
      with-timeout --ms=5000:
        socket.out.write "after interruption"
        expect-equals "after interruption".to-byte-array (socket.in.read-bytes 18)
    finally:
      socket.close
  finally:
    restored.close
  print "ESP8285 $(deadline ? "deadline" : "cancellation") isolation and controlled recovery: PASS"
