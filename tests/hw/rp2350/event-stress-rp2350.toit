// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show expect-throw
import gpio
import i2c
import monitor
import uart

GPIO-PIN ::= 34
UART-TX ::= 16
I2C-ADDRESS ::= 0x55

GPIO-ROUNDS ::= 12
GPIO-TRANSITIONS ::= 24
UART-ROUNDS ::= 16
UART-FRAMES ::= 64
I2C-ROUNDS ::= 16
I2C-TRANSFERS ::= 16
TIMER-ITERATIONS ::= 800

STEP-TIMEOUT-MS ::= 500
TEST-TIMEOUT-MS ::= 60_000
GPIO-ARM-DELAY-MS ::= 5

/**
Stresses the shared RP2350 peripheral event task without an external peer.

GP34 must remain unconnected. The ESP32 rig program must be stopped, with its
  I2C pins left as inputs, so address 0x55 remains absent on GP4/5 and GP10/11.
Internal pull-ups keep both I2C buses idle-high.
*/
main:
  print "event-stress-rp2350: starting concurrent workers"
  with-timeout --ms=TEST-TIMEOUT-MS:
    Task.group [
      :: gpio-worker,
      :: uart-worker,
      :: i2c-worker,
      :: timer-worker,
    ]
    final-lifecycle-check

  print "event-stress-rp2350: PASS shared dispatch, polling, and teardown"

gpio-worker:
  GPIO-ROUNDS.repeat:
    // The pin is unconnected, so push-pull output plus input is safe here.
    pin := gpio.Pin GPIO-PIN --input --output --value=0
    try:
      ready-a := monitor.Channel 1
      ready-b := monitor.Channel 1
      Task.group [
        :: gpio-waiter pin ready-a,
        :: gpio-waiter pin ready-b,
        :: gpio-toggler pin ready-a ready-b,
      ]
    finally:
      pin.close
  print "event-stress-rp2350: GPIO worker complete"

gpio-waiter pin/gpio.Pin ready/monitor.Channel:
  GPIO-TRANSITIONS.repeat: | iteration/int |
    expected := (iteration + 1) & 1
    with-timeout --ms=STEP-TIMEOUT-MS: ready.send iteration
    with-timeout --ms=STEP-TIMEOUT-MS: pin.wait-for expected

gpio-toggler
    pin/gpio.Pin
    ready-a/monitor.Channel
    ready-b/monitor.Channel:
  GPIO-TRANSITIONS.repeat: | iteration/int |
    a := with-timeout --ms=STEP-TIMEOUT-MS: ready-a.receive
    b := with-timeout --ms=STEP-TIMEOUT-MS: ready-b.receive
    if a != iteration or b != iteration:
      throw "GPIO waiter barrier mismatch at $iteration: $a/$b"
    // Let both waiters arm the level interrupt before changing SIO.
    with-timeout --ms=STEP-TIMEOUT-MS: sleep --ms=GPIO-ARM-DELAY-MS
    pin.set (iteration + 1) & 1

uart-worker:
  UART-ROUNDS.repeat: | round/int |
    port := uart.Port --tx=UART-TX --baud-rate=115_200
    try:
      UART-FRAMES.repeat: | frame-index/int |
        size := 1 + (frame-index & 7)
        frame := ByteArray size: | byte-index/int |
          (round * 37 + frame-index * 11 + byte-index) & 0xff
        // Small back-to-back flushes exercise the TX idle poll handoff.
        with-timeout --ms=STEP-TIMEOUT-MS:
          port.out.write frame
          port.out.flush
    finally:
      port.close
  print "event-stress-rp2350: UART worker complete"

i2c-worker:
  I2C-ROUNDS.repeat: | round/int |
    bus0 := i2c.Bus --sda=4 --scl=5 --frequency=100_000 --pull-up
    try:
      bus1 := i2c.Bus --sda=10 --scl=11 --frequency=100_000 --pull-up
      try:
        device0 := bus0.device I2C-ADDRESS --frequency=100_000
        try:
          device1 := bus1.device I2C-ADDRESS --frequency=100_000
          try:
            I2C-TRANSFERS.repeat: | transfer/int |
              payload := #[round & 0xff, transfer & 0xff]
              // Run both controller state machines at the same time.
              Task.group [
                :: expect-nack device0 payload,
                :: expect-nack device1 payload,
              ]
          finally:
            device1.close
        finally:
          device0.close
      finally:
        bus1.close
    finally:
      bus0.close
  print "event-stress-rp2350: I2C worker complete"

expect-nack device/i2c.Device payload/ByteArray:
  expect-throw "I2C_NACK":
    with-timeout --ms=STEP-TIMEOUT-MS: device.write payload

timer-worker:
  TIMER-ITERATIONS.repeat: | iteration/int |
    delay := 1 + (iteration % 4)
    with-timeout --ms=STEP-TIMEOUT-MS: sleep --ms=delay
  print "event-stress-rp2350: timer worker complete"

final-lifecycle-check:
  pin := gpio.Pin GPIO-PIN --input --output --value=0
  pin.close

  port := uart.Port --tx=UART-TX --baud-rate=115_200
  port.close

  bus0 := i2c.Bus --sda=4 --scl=5 --frequency=100_000 --pull-up
  try:
    bus1 := i2c.Bus --sda=10 --scl=11 --frequency=100_000 --pull-up
    bus1.close
  finally:
    bus0.close
