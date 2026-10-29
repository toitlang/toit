// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.
import gpio
import uart
import expect show *
import monitor show Semaphore

// Reuse the SPI wires for flow control: nRF RTS P0.08 -> ESP CTS GPIO18,
// and nRF CTS P0.09 <- ESP RTS GPIO23. TX/RX retain the usual UART wires.
main:
  ack := gpio.Pin 33 --input --pull-down
  sequence := 0
  request := : | command/string |
    sequence++
    print "GPIO REQUEST $sequence $command"
    with-timeout --ms=5000: ack.wait-for (sequence & 1)

  // Control CTS independently to prove that the nRF transmitter honors it.
  request.call "UART_OPEN 32 33 115200 1"
  request.call "CONFIG 23 OUT 1"
  port := uart.Port --tx=36 --rx=37 --rts=8 --cts=9 --baud-rate=115200
  expect-equals "ALREADY_IN_USE" (catch: gpio.Pin 8 --output)
  expect-equals "ALREADY_IN_USE" (catch: gpio.Pin 9 --input)
  done := Semaphore
  sent := false
  failure := null
  sender := task::
    failure = catch: port.out.write (pattern 257) --flush
    sent = true
    done.up
  sleep --ms=50
  expect (not sent)
  expect-equals DEADLINE-EXCEEDED-ERROR (catch:
    with-timeout --ms=20: port.in.read)
  request.call "CONFIG 23 OUT 0"
  with-timeout --ms=3000:
    receive-pattern port 257
    done.down
  if failure: throw failure
  sender.cancel
  expect-equals 0 port.errors
  port.close
  request.call "UART_CLOSE"
  request.call "CONFIG 23 IN 0"
  print "UART CTS blocks and releases transmission PASS"

  // The sender uses CTS from the nRF receiver. Stall the Toit reader long
  // enough to fill the native ring, then demand the complete, ordered stream.
  [false, true].do: | large |
    [115200, 1000000].do: | baud |
      request.call "UART_FLOW_OPEN 32 33 $baud 1 23 18"
      port = uart.Port --tx=36 --rx=37 --rts=8 --cts=9
          --baud-rate=baud
          --large-buffers=large
      request.call "UART_SEND 32768"
      sleep --ms=2000
      expect-equals 0 port.errors
      // Reconfigure while RX is paused; this must not bypass buffer credit.
      port.baud-rate = baud
      with-timeout --ms=7000: receive-pattern port 32768
      expect-equals 0 port.errors
      request.call "UART_SEND 1025"
      with-timeout --ms=2000: receive-pattern port 1025
      expect-equals 0 port.errors
      port.close
      request.call "UART_CLOSE"
      request.call "CONFIG 18 DOWN 0"
      request.call "CHECK 18 0"
      print "UART RTS backpressure baud=$baud large=$large PASS"

  request.call "UART_FLOW_OPEN 32 33 1000000 1 23 18"
  port = uart.Port --tx=36 --rx=37 --rts=8 --cts=9 --baud-rate=1000000 --no-large-buffers
  request.call "UART_SEND 32768"
  sleep --ms=500
  expect-equals 0 port.errors
  port.close
  request.call "UART_CLOSE"
  print "UART close while receiver is paused PASS"

  request.call "UART_OPEN 32 33 115200 1"
  request.call "CONFIG 23 OUT 1"
  port = uart.Port --tx=36 --rx=37 --rts=8 --cts=9 --baud-rate=115200
  done = Semaphore
  failure = null
  sender = task::
    failure = catch: port.out.write (pattern 1024) --flush
    done.up
  sleep --ms=50
  port.close
  with-timeout --ms=1000: done.down
  expect-equals "CLOSED" failure
  sender.cancel
  request.call "UART_CLOSE"
  print "UART close while CTS blocks transmission PASS"

  // Leave TX blocked and RX enabled for independent process-teardown checks.
  port = uart.Port --tx=36 --rx=37 --rts=8 --cts=9 --baud-rate=115200
  expect-equals 1024 (port.out.try-write (pattern 1024))
  sleep --ms=20
  ack.close
  print "NRF5340 UART FLOW PASS"

pattern size/int -> ByteArray:
  return ByteArray size: (it * 73 + size) & 0xff

receive-pattern port/uart.Port size/int:
  received := 0
  while received < size:
    chunk := port.in.read
    expect chunk != null
    expect received + chunk.size <= size
    chunk.size.repeat: | i |
      expect-equals (((received + i) * 73 + size) & 0xff) chunk[i]
    received += chunk.size
