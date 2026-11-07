// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *
import gpio
import monitor
import system
import uart
import ..rp2350.uart-rp2350 as shared

main:
  with-timeout --ms=120_000:
    // RP2040 lacks the RP2350 UART_AUX function. Reject before reserving pins.
    expect-throw "INVALID_ARGUMENT": uart.Port --tx=14 --rx=15 --baud-rate=115_200
    expect-throw "INVALID_ARGUMENT": uart.Port --tx=16 --rx=5 --baud-rate=115_200
    expect-throw "INVALID_ARGUMENT": uart.Port --tx=30 --baud-rate=115_200
    test-traffic
    test-overflow
    20.repeat: | i/int |
      port := uart.Port --tx=16 --rx=17 --baud-rate=115_200
      try:
        shared.send-line port "HELLO reopen-$i"
        shared.expect-line port "READY reopen-$i"
        shared.test-echo port 257
        close-waiter port
      finally:
        port.close
      system.process-stats --gc
    port := uart.Port --tx=16 --rx=17 --baud-rate=115_200
    try:
      shared.send-line port "QUIT"
      shared.expect-line port "BYE"
    finally:
      port.close
  print "uart-stress-rp2040: PASS"

test-traffic:
  port := uart.Port --tx=16 --rx=17 --baud-rate=115_200 --large-buffers
  ticks := 0
  collector := task::
    retained := List 8: ByteArray 1024 --initial=it
    while true:
      system.process-stats --gc
      retained.do: expect-equals it[0] it[1023]
      ticks++
      sleep --ms=10
  try:
    expect-throw "ALREADY_IN_USE": uart.Port --tx=16 --rx=17 --baud-rate=115_200
    expect-throw "ALREADY_IN_USE": gpio.Pin 16 --input
    shared.send-line port "HELLO stress"
    shared.expect-line port "READY stress"
    [1, 31, 256, 4096, 8193].do: shared.test-echo port it
    shared.change-baud port 921_600
    12.repeat: shared.test-echo port 8193
    shared.change-baud port 9_600
    shared.test-echo port 257
    shared.change-baud port 115_200
    expect-equals 0 port.errors
    expect (ticks > 0)
  finally:
    collector.cancel
    port.close
  print "uart-stress-rp2040: PASS traffic, baud, GC and timers"

test-overflow:
  // The deliberately small buffer makes loss observable and checks recovery.
  port := uart.Port --tx=16 --rx=17 --baud-rate=115_200 --no-large-buffers
  try:
    shared.change-baud port 921_600
    shared.test-overflow-and-recovery port
    shared.change-baud port 115_200
  finally:
    port.close
  print "uart-stress-rp2040: PASS overflow accounting and recovery"

close-waiter port/uart.Port:
  ready := monitor.Latch
  done := monitor.Latch
  result/any := "pending"
  error := null
  task::
    ready.set true
    try:
      error = catch: result = port.in.read
    finally:
      critical-do: done.set true
  ready.get
  sleep --ms=1
  port.close
  with-timeout --ms=1000: done.get
  expect-equals null error
  expect-equals null result
