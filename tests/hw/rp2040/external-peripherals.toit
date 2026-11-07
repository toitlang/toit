// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *
import gpio.adc show Adc
import i2c
import monitor
import spi
import system
import uart

import .external-protocol show *

ADDRESS ::= 0x42

main:
  port := uart.Port --tx=16 --rx=17 --baud-rate=115_200
  try:
    print "external-peripherals-rp2040: READY"
    expect-equals "START" (receive port)
    test-adc port
    [100_000, 400_000].do: | frequency/int |
      test-controller port frequency
      test-target port frequency
    test-spi-controller port
    test-spi-target port
    test-spi-target-reuse port
    test-spi-buffer-target port
    test-spi-partial-byte port
    request port "QUIT"
    print "external-peripherals-rp2040: PASS"
  finally:
    port.close

test-adc port/uart.Port:
  adc := Adc 26
  readings := []
  try:
    // Synchronize every sample group with a settled DAC level. No sorting can
    // hide swapped, missing, or out-of-order stimulus levels.
    7.repeat: | level/int |
      request port "DAC $level"
      sleep --ms=20
      values := []
      9.repeat:
        values.add (adc.get --samples=129)
        raw := adc.get --raw
        expect (0 <= raw <= 4095)
        expect ((raw * 3.3 / 4095 - values.last).abs < 0.08)
        sleep --ms=2
      measured := (values.sort)[4]
      readings.add measured
      print "ADC GP26 requested=$(level * 0.5)V measured=$measured V"
    low/float := readings.first
    high/float := readings.last
    expect (0.0 <= low <= 0.25)
    expect (2.65 <= high <= 3.25)
    5.repeat: | index/int |
      expected := low + (high - low) * (index + 1) / 6.0
      expect ((readings[index + 1] - expected).abs <= 0.10)
    request port "DAC-CLOSE"
  finally:
    adc.close
  print "external-peripherals-rp2040: PASS ADC staircase"

test-controller port/uart.Port frequency/int:
  // One wired I2C instance. Other-instance lifecycle coverage is separate.
  bus := i2c.Bus --sda=4 --scl=5 --frequency=frequency --pull-up
  device := bus.device ADDRESS --timeout-us=2_000_000
  try:
    [1, 4, 16, 32].do: | size/int |
      request port "CONTROLLER $size"
      expect-equals (pattern size 7) (device.read size)
      request port "CLOSE"
      request port "CONTROLLER $size"
      expect-equals (pattern size 7) (device.write-read (pattern 2 23) size)
      request port "CHECK 2"
      request port "CLOSE"
    [1, 31, 32, 33, 63, 64, 65, 257, 1025].do: | size/int |
      request port "CONTROLLER 1"
      device.write (pattern size 23)
      request port "CHECK $size"
      request port "CLOSE"
      print "I2C controller write $size PASS"
    expect-throw "I2C_NACK": device.write #[1]
  finally:
    device.close
    bus.close
  print "external-peripherals-rp2040: PASS I2C controller frequency=$frequency"

test-target port/uart.Port frequency/int:
  request port "TARGET $frequency"
  [1, 31, 32, 33, 63, 64, 65, 257, 1025].do: | size/int |
    target := i2c.Target
        --sda=4
        --scl=5
        --address=ADDRESS
        --send-buffer-size=2048
        --receive-buffer-size=2048
        --pull-up
    try:
      target.write (pattern size 7)
      request port "TRANSFER $size"
      expect-equals (pattern size 23) (with-timeout --ms=2_000: target.read)
    finally:
      target.close
    print "I2C target write-read $size PASS"
  request port "CLOSE"
  print "external-peripherals-rp2040: PASS I2C target frequency=$frequency"

test-spi-controller port/uart.Port:
  bus := spi.Bus --mosi=7 --miso=4 --clock=6
  try:
    4.repeat: | mode/int |
      device := bus.device --cs=5 --frequency=100_000 --mode=mode
      try:
        // The classic ESP32 non-DMA target has a 64-byte transfer limit.
        [1, 4, 16, 31, 60].do: | size/int |
          request port "SPI-CONTROLLER $mode $size"
          data := pattern size 23
          with-timeout --ms=3_000: device.transfer data --read
          expect-equals (pattern size 7) data
          expect-equals "OK" (receive port)
      finally:
        device.close
      print "SPI controller mode=$mode PASS"
  finally:
    bus.close
  print "external-peripherals-rp2040: PASS SPI controller"

test-spi-target port/uart.Port:
  // The RP2040 hardware target supports modes 1 and 3.
  [1, 3].do: | mode/int |
    [false, true].do: | dma/bool |
      sizes := dma ? [1, 7, 31, 64, 257, 1025] : [1, 7, 31, 64]
      sizes.do: | size/int |
        request port "SPI-TARGET $mode $size"
        target := spi.Target
            --mosi=4
            --miso=7
            --clock=6
            --cs=5
            --mode=mode
            --max-transfer-size=(dma ? size : 64)
            --dma=dma
        try:
          data := with-timeout --ms=5_000:
            target.transfer (pattern size 7)
                --receive-size=size
                --when-armed=(:
                  send port "CLOCK"
                  expect-equals "CLOCKING" (receive port))
          expect-equals (pattern size 23) data
          expect-equals "OK" (receive port)
        finally:
          target.close
      print "SPI target mode=$mode dma=$dma PASS"
  print "external-peripherals-rp2040: PASS SPI target"

test-spi-target-reuse port/uart.Port:
  [1, 3].do: | mode/int |
    [false, true].do: | dma/bool |
      capacity := dma ? 257 : 64
      target := spi.Target
          --mosi=4
          --miso=7
          --clock=6
          --cs=5
          --mode=mode
          --max-transfer-size=capacity
          --dma=dma
      try:
        seed := 41
        // Leave prefetched TX bytes and an incomplete RX buffer, then arm a
        // different pattern on the same target. Check both ends of the wire.
        [1, 7, 31, capacity - 1, 3, capacity].do: | size/int |
          request port "SPI-TARGET $mode $size $seed"
          spi-target-exchange port target capacity size seed
          seed += 17

        // The helper constructs its controller and holds CS idle until CLOCK.
        // It remains in that state across the aborted arm and subsequent reuse.
        request port "SPI-TARGET $mode $capacity $seed"
        armed := false
        expect-throw DEADLINE-EXCEEDED-ERROR:
          with-timeout --ms=100:
            target.transfer (pattern capacity 199)
                --when-armed=(: armed = true)
        expect armed
        spi-target-exchange port target capacity capacity seed
        seed += 17

        request port "SPI-TARGET $mode $capacity $seed"
        spi-target-interrupt port target capacity --no-close
        spi-target-exchange port target capacity capacity seed
        seed += 17

        // Also interrupt after clocks have moved data, with CS still asserted.
        // The helper verifies the prefix before reporting ACTIVE.
        [false, true].do: | close/bool |
          request port "SPI-TARGET-PAUSE $mode"
          spi-target-interrupt port target capacity --close=close --active
          if close:
            target = spi.Target
                --mosi=4
                --miso=7
                --clock=6
                --cs=5
                --mode=mode
                --max-transfer-size=capacity
                --dma=dma
          request port "SPI-TARGET $mode $capacity $seed"
          spi-target-exchange port target capacity capacity seed
          seed += 17
      finally:
        target.close
      print "SPI target short/cancel/close reuse mode=$mode dma=$dma PASS"
  print "external-peripherals-rp2040: PASS SPI target recovery"

spi-target-exchange port/uart.Port target/spi.Target capacity/int size/int seed/int:
  data := with-timeout --ms=5_000:
    target.transfer (pattern capacity seed)
        --receive-size=capacity
        --when-armed=(:
          send port "CLOCK"
          expect-equals "CLOCKING" (receive port))
  expect-equals (pattern size 23) data
  expect-equals "OK" (receive port)

spi-target-interrupt port/uart.Port target/spi.Target capacity/int --close/bool --active/bool=false:
  armed := monitor.Latch
  done := monitor.Latch
  error := null
  worker := task::
    try:
      error = catch:
        target.transfer (pattern capacity 199)
            --when-armed=(:
              if active:
                send port "CLOCK"
                expect-equals "ACTIVE" (receive port)
              armed.set true)
    finally: | is-exception exception |
      // Task cancellation deliberately bypasses catch and keeps unwinding.
      if is-exception: error = exception.value
      critical-do --no-respect-deadline: done.set true
  try:
    with-timeout --ms=2_000: armed.get
    if close:
      target.close
    else:
      worker.cancel
    with-timeout --ms=2_000: done.get
    expect-equals (close ? "CLOSED" : CANCELED-ERROR) error
    if active: request port "RELEASE"
  finally:
    worker.cancel

test-spi-buffer-target port/uart.Port:
  [1, 3].do: | mode/int |
    [false, true].do: | dma/bool |
      capacity := dma ? 257 : 32
      request port "SPI-BUFFER $mode $capacity"
      response := pattern capacity 7
      target := spi.BufferTarget response
          --mosi=4
          --miso=7
          --clock=6
          --cs=5
          --mode=mode
          --buffer-size=capacity
          --receive-queue-depth=3
          --dma=dma
      ticks := 0
      collector := task::
        while true:
          system.process-stats --gc
          ticks++
          sleep --ms=2
      try:
        // The constructor must own a copy even after the caller changes its
        // input. No receive call runs until all three transactions finish.
        response.fill 0
        send port "CLOCK"
        expect-equals "MIXED" (receive port)
        expect-equals (pattern 3 23) (with-timeout --ms=2_000: target.receive)
        expect-equals (pattern capacity 41) (with-timeout --ms=2_000: target.receive)
        expect-equals (pattern 7 59) (with-timeout --ms=2_000: target.receive)
        expect-equals 0 target.dropped-receive-count
        expect-throw DEADLINE-EXCEEDED-ERROR:
          with-timeout --ms=20: target.receive

        response = pattern capacity 113
        target.write 0 response
        target[capacity - 1] = response[capacity - 1] ^ 0xff
        response[capacity - 1] ^= 0xff
        expect-equals response (target.read 0 capacity)
        expect-equals response.last target[capacity - 1]
        response.fill 0
        // A transaction retires response bytes prefetched before the update.
        send port "NEXT"
        expect-equals "WARMED" (receive port)
        expect-equals (pattern 1 99) (with-timeout --ms=2_000: target.receive)
        send port "FLOOD"
        expect-equals "FLOODED" (receive port)
        expect-equals 3 target.dropped-receive-count
        3.repeat: | index/int |
          expect-equals (pattern 7 (100 + index))
              (with-timeout --ms=2_000: target.receive)
        expect-throw DEADLINE-EXCEEDED-ERROR:
          with-timeout --ms=20: target.receive

        send port "RECOVER"
        expect-equals "RECOVERED" (receive port)
        expect-equals (pattern capacity 205) (with-timeout --ms=2_000: target.receive)
        expect-equals 3 target.dropped-receive-count
        expect (ticks > 0)
        spi-buffer-close-waiter target
        request port "FINISH"
      finally:
        collector.cancel
        target.close
      print "SPI buffer target queue/rearm/GC mode=$mode dma=$dma PASS"
  print "external-peripherals-rp2040: PASS SPI buffer target"

spi-buffer-close-waiter target/spi.BufferTarget:
  ready := monitor.Latch
  done := monitor.Latch
  error := null
  worker := task::
    ready.set true
    try:
      error = catch: target.receive
    finally:
      critical-do --no-respect-deadline: done.set true
  try:
    ready.get
    sleep --ms=1
    target.close
    with-timeout --ms=2_000: done.get
    expect-equals "CLOSED" error
  finally:
    worker.cancel

test-spi-partial-byte port/uart.Port:
  [1, 3].do: | mode/int |
    [false, true].do: | dma/bool |
      target := spi.Target
          --mosi=4
          --miso=7
          --clock=6
          --cs=5
          --mode=mode
          --max-transfer-size=4
          --dma=dma
      try:
        // Whole-byte controls verify the helper's command-phase bit order.
        [8, 16, 1, 7, 9, 11, 15].do: | bits/int |
          request port "SPI-PARTIAL $mode $bits"
          data := with-timeout --ms=2_000:
            target.transfer (pattern 4 7)
                --when-armed=(:
                  send port "CLOCK"
                  expect-equals "CLOCKING" (receive port))
          expect-equals (#[0xa7, 0xf9][..(bits >> 3)]) data
          expect-equals "OK" (receive port)
          // A complete transfer on the same target must start at bit zero.
          request port "SPI-TARGET $mode 4 113"
          spi-target-exchange port target 4 4 113
      finally:
        target.close
      print "SPI partial-byte/reuse mode=$mode dma=$dma PASS"
  print "external-peripherals-rp2040: PASS SPI partial byte"
