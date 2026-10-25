// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.
import gpio
import uart
import expect show *
import monitor show Semaphore

// The fixture echoes binary data. GPIO acknowledgements synchronize changes
// of baud rate and pin routing without assumptions about USB host latency.
main:
  ack := gpio.Pin 33 --input --pull-down
  sequence := 0
  request := : | command/string |
    sequence++
    print "GPIO REQUEST $sequence $command"
    with-timeout --ms=5000: ack.wait-for (sequence & 1)
  request.call "UART_OPEN 32 33 115200 1"
  port := uart.Port --tx=36 --rx=37 --baud-rate=115200
  try:
    expect-equals 115200 port.baud-rate
    expect-equals "ALREADY_IN_USE" (catch: gpio.Pin 36 --output)
    expect-equals "ALREADY_IN_USE" (catch: gpio.Pin 37 --input)
    expect-equals "ALREADY_IN_USE" (catch: uart.Port --tx=8 --rx=9 --baud-rate=115200)
    free-pin := gpio.Pin 8 --input
    free-pin.close
    expect-equals DEADLINE-EXCEEDED-ERROR (catch: with-timeout --ms=50: port.in.read)
    [1, 2, 255, 256, 257, 1024, 4097].do: | size | exchange port size
    expect-equals 0 port.errors
    print "UART binary transfers and cancellation PASS"

    [9600, 460800, 1000000, 115200].do: | baud |
      request.call "UART_BAUD $baud"
      port.baud-rate = baud
      expect-equals baud port.baud-rate
      exchange port 513
      if baud == 1000000: exchange port 16385
      expect-equals 0 port.errors
      print "UART baud=$baud PASS"
    expect ((catch: port.baud-rate = 12345) != null)
    expect-equals 115200 port.baud-rate
    exchange port 257
    port.close
    request.call "UART_CLOSE"
    request.call "CONFIG 32 DOWN 0"
    request.call "CHECK 32 0"
    expect ((catch: uart.Port --tx=36 --rx=37 --baud-rate=115200 --data-bits=7) != null)
    free-pin = gpio.Pin 36 --input
    free-pin.close
    print "UART failed configuration releases pins PASS"

    64.repeat: | cycle |
      alternate := cycle % 2 == 1
      tx := alternate ? 8 : 36
      rx := alternate ? 9 : 37
      partner-rx := alternate ? 18 : 32
      partner-tx := alternate ? 23 : 33
      request.call "UART_OPEN $partner-rx $partner-tx 115200 1"
      port = uart.Port --tx=tx --rx=rx --baud-rate=115200
      exchange port 257
      expect-equals 0 port.errors
      port.close
      request.call "UART_CLOSE"
      request.call "CONFIG $partner-rx DOWN 0"
      request.call "CHECK $partner-rx 0"
    print "UART 64 reopen and remap cycles PASS"

    request.call "UART_OPEN 32 33 115200 2"
    port = uart.Port --tx=36 --rx=37 --baud-rate=115200 --parity=uart.Port.PARITY-EVEN
    exchange port 513
    expect-equals 0 port.errors
    port.close
    request.call "UART_CLOSE"
    print "UART even parity PASS"

    request.call "UART_OPEN 32 33 115200 1"
    port = uart.Port --rx=37 --baud-rate=115200
    request.call "UART_SEND 1025"
    with-timeout --ms=3000: receive-pattern port 1025
    expect-equals 0 port.errors
    expect ((catch: port.out.write #[42]) != null)
    done := Semaphore
    result/any := "pending"
    waiter := task::
      result = port.in.read
      done.up
    sleep --ms=10
    port.close
    with-timeout --ms=1000: done.down
    expect-equals null result
    waiter.cancel
    request.call "UART_CLOSE"
    print "UART receive-only and close while waiting PASS"

    request.call "UART_OPEN 32 33 115200 1"
    port = uart.Port --tx=36 --rx=37 --baud-rate=115200 --no-large-buffers
    request.call "UART_SEND 8192"
    sleep --ms=1500
    expect-equals 4096 port.errors
    chunk := port.in.read
    expect-equals 4096 chunk.size
    chunk.size.repeat: | i | expect-equals ((i * 73) & 0xff) chunk[i]
    expect-equals DEADLINE-EXCEEDED-ERROR (catch: with-timeout --ms=50: port.in.read)
    exchange port 257
    expect-equals 4096 port.errors
    port.close
    request.call "UART_CLOSE"
    print "UART receive overflow accounting and recovery PASS"

    request.call "UART_OPEN 32 33 1000000 1"
    port = uart.Port --rx=37 --baud-rate=1000000 --large-buffers
    request.call "UART_SEND 8192"
    sleep --ms=300
    with-timeout --ms=1000: receive-pattern port 8192
    expect-equals 0 port.errors
    port.close
    request.call "UART_CLOSE"
    print "UART large receive buffer PASS"

    8.repeat:
      request.call "UART_OPEN 32 33 115200 1"
      port = uart.Port --tx=36 --rx=37 --baud-rate=115200
      request.call "UART_SEND 8192"
      sleep --ms=150
      port.close
      request.call "UART_CLOSE"
      request.call "UART_OPEN 32 33 115200 1"
      port = uart.Port --tx=36 --rx=37 --baud-rate=115200
      expect-equals 1024 (port.out.try-write (ByteArray 1024 --initial=0x55))
      port.close
      request.call "UART_CLOSE"
    print "UART close during receive and transmit traffic PASS"

    // Leave a transmit-only port open to test process teardown independently
    // of explicit close. The host checks that TX no longer drives high.
    port = uart.Port --tx=36 --baud-rate=115200
    port.out.write #[0, 255, 85, 170] --flush
    request.call "CHECK 32 1"
    print "NRF5340 UART PASS"
  finally:
    ack.close

exchange port/uart.Port size/int:
  data := ByteArray size: (it * 73 + size) & 0xff
  done := Semaphore
  received := 0
  failure := null
  receiver := task::
    failure = catch:
      while received < size:
        chunk := port.in.read
        expect (chunk != null)
        expect received + chunk.size <= size
        chunk.size.repeat: | i |
          if data[received + i] != chunk[i]:
            throw "UART mismatch at $(received + i)/$size: expected $(data[received + i]), got $(chunk[i]); errors=$(port.errors)"
        received += chunk.size
    done.up
  try:
    with-timeout --ms=5000:
      port.out.write data --flush
      done.down
    if failure: throw failure
    expect-equals size received
  finally:
    receiver.cancel

receive-pattern port/uart.Port size/int:
  received := 0
  while received < size:
    chunk := port.in.read
    expect (chunk != null)
    expect received + chunk.size <= size
    chunk.size.repeat: | i |
      expect-equals (((received + i) * 73 + size) & 0xff) chunk[i]
    received += chunk.size
