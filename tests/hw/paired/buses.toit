// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import i2c
import rmt
import pulse-counter
import spi
import uart
import .session

pattern size/int seed/int -> ByteArray:
  return ByteArray size: (it * 37 + seed) & 255

run session/Session cs/int clk/int mosi/int miso/int --testee-dma/bool --tester-dma/bool:
  port := session.port
  [true, false].do: | testee-controller |
    controller := testee-controller == session.is-testee
    4.repeat: | mode |
      dma := testee-controller ? tester-dma : testee-dma
      sizes := dma ? [1, 3, 31, 32, 33, 127, 128, 129, 1024, 4092] : [16, 31, 32, 33, 64]
      sizes.do: | size |
        session.run-case "SPI testee-controller=$testee-controller mode=$mode size=$size":
          observed := spi-case port controller mode size dma cs clk mosi miso
          peer-observed := session.observation observed
          if not session.is-testee:
            expect-equals (pattern size (testee-controller ? 93 : 17)) peer-observed
    print "SPI role $(controller ? "controller" : "target") passed"
  [true, false].do: | testee-controller |
    controller := testee-controller == session.is-testee
    [50_000, 100_000].do: | frequency |
      [1, 16, 255, 1024].do: | size |
        session.run-case "I2C testee-controller=$testee-controller frequency=$frequency size=$size":
          observed := i2c-case port controller frequency size cs clk
          peer-observed := session.observation observed
          if not session.is-testee:
            expected := testee-controller ? (pattern 32 123) : (pattern size 47)
            expect-equals expected peer-observed
    print "I2C role $(controller ? "controller" : "target") passed"
  [true, false].do: | testee-transmits |
    session.run-case "RMT testee-transmits=$testee-transmits":
      observed := rmt-case port (testee-transmits == session.is-testee) cs
      peer-observed := session.observation observed
      if not session.is-testee and not testee-transmits: verify-rmt peer-observed
  session.run-case "RMT transmit across refill boundaries":
    if session.is-testee:
      output := rmt.Out cs --resolution=1_000_000
      try:
        session.send "ready"
        expect-equals "armed" session.receive
        output.write (rmt.Signals.alternating 2048 --first-level=1: 10) --done-level=0
        session.send "sent"
        expect-equals "counted" session.receive
      finally:
        output.close
    else:
      expect-equals "ready" session.receive
      counter := pulse-counter.Unit cs
      try:
        session.send "armed"
        expect-equals "sent" session.receive
        expect-equals 1024 counter.value
      finally:
        counter.close
      session.send "counted"

spi-case port/uart.Port controller/bool mode/int size/int dma/bool cs/int clk/int mosi/int miso/int:
  tx := pattern size (controller ? 17 : 93)
  expected := pattern size (controller ? 93 : 17)
  observed := null
  if controller:
    bus := spi.Bus --clock=clk --mosi=mosi --miso=miso
    device := bus.device --cs=cs --frequency=400_000 --mode=mode --cs-setup-cycles=2
    try:
      port.out.write-byte 1
      expect-equals 2 port.in.read-byte
      device.transfer tx --read
      observed = tx
      expect-equals expected tx
      expect-equals 3 port.in.read-byte
    finally:
      device.close
      bus.close
    port.out.write-byte 4
    expect-equals 5 port.in.read-byte
  else:
    expect-equals 1 port.in.read-byte
    target := spi.Target --clock=clk --cs=cs --mosi=mosi --miso=miso
        --mode=mode
        --max-transfer-size=size
        --dma=dma
    try:
      if mode == 0 and size == 32:
        // The controller is waiting for the armed message: no CS can arrive.
        error := catch --unwind=(: it != DEADLINE-EXCEEDED-ERROR):
          with-timeout --ms=20:
            target.transfer tx --receive-size=size
        expect-equals DEADLINE-EXCEEDED-ERROR error
      // Reuse the same target after cancellation, without closing it first.
      received := target.transfer tx --receive-size=size --when-armed=:
        port.out.write-byte 2
        port.out.flush
      observed = received
      expect-equals expected received
      port.out.write-byte 3
      expect-equals 4 port.in.read-byte
    finally:
      target.close
    port.out.write-byte 5
  return observed

i2c-case port/uart.Port controller/bool frequency/int size/int cs/int clk/int:
  tx := pattern size 47
  response := pattern 32 123
  observed := null
  if controller:
    // Let the target establish idle pull-ups before attaching the controller.
    // Otherwise a pin transition left by SPI can look like an I2C START.
    port.out.write-byte 1
    expect-equals 2 port.in.read-byte
    bus := i2c.Bus --sda=cs --scl=clk
    device := bus.device 0x42 --frequency=frequency
    try:
      if size == 255:
        absent := bus.device 0x43 --frequency=frequency
        expect-throw "I2C_NACK": absent.write-read tx response.size
        absent.close
      guarded := ByteArray (response.size + 2) --initial=0xa5
      device.write-read-into --tx-buffer=tx --rx-buffer=guarded[1..guarded.size - 1]
      expect-equals 0xa5 guarded[0]
      expect-equals 0xa5 guarded[guarded.size - 1]
      observed = guarded[1..guarded.size - 1]
      expect-equals response observed
      port.out.write-byte 3
      expect-equals 4 port.in.read-byte
    finally:
      device.close
      bus.close
  else:
    expect-equals 1 port.in.read-byte
    target := i2c.Target --sda=cs --scl=clk --address=0x42
        --send-buffer-size=64
        --receive-buffer-size=2048
        --pull-up
    try:
      target.write response
      port.out.write-byte 2
      observed = target.read
      expect-equals tx observed
      expect-equals 3 port.in.read-byte
    finally:
      target.close
    port.out.write-byte 4
  return observed

rmt-case port/uart.Port transmit/bool cs/int:
  observed := null
  if transmit:
    out := rmt.Out cs --resolution=1_000_000
    port.out.write-byte 1
    expect-equals 2 port.in.read-byte
    signals := rmt.Signals.alternating 11 --first-level=1: 50 + it * 10
    out.write signals --done-level=0
    expect-equals 3 port.in.read-byte
    out.close
    port.out.write-byte 4
  else:
    expect-equals 1 port.in.read-byte
    input := rmt.In cs --resolution=1_000_000
    input.start-reading --min-ns=1000 --max-ns=500_000
    port.out.write-byte 2
    signals := input.wait-for-data
    observed = List signals.size: [signals.level it, signals.period it]
    verify-rmt observed
    input.close
    port.out.write-byte 3
    expect-equals 4 port.in.read-byte
  return observed

verify-rmt observed/List:
  expect-equals 12 observed.size
  11.repeat:
    expect-equals (1 - it % 2) observed[it][0]
    expect (observed[it][1] - (50 + it * 10)).abs <= 3
  expect-equals 0 observed[11][1]
