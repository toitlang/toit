// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *
import gpio
import gpio.adc
import i2c
import spi
import system

// Only unused header pads are used. Check them with weak bias first, before
// enabling any controller outputs. This tests lifecycle, not external data
// integrity or ADC accuracy.
main:
  [18, 19, 20, 21, 26, 27].do: | number/int |
    pin := gpio.Pin number --input --pull-up
    try:
      sleep --ms=5
      expect-equals 1 pin.get
      pin.set-pull --down
      sleep --ms=5
      expect-equals 0 pin.get
    finally:
      pin.close
  print "peripheral-lifecycle-rp2040: PASS input-only weak-pull check"
  with-timeout --ms=30_000:
    10.repeat:
      test-adc
      test-i2c
      test-spi
      system.process-stats --gc
  print "peripheral-lifecycle-rp2040: PASS"

test-adc:
  first := adc.Adc 26
  second := adc.Adc 27
  try:
    expect-throw "ALREADY_IN_USE": adc.Adc 26
    expect-throw "ALREADY_IN_USE": gpio.Pin 26 --input
    expect-throw "OUT_OF_RANGE": adc.Adc 30
    expect-throw "PERMISSION_DENIED": adc.Adc 29
    raw := first.get --raw
    expect (0 <= raw <= 4095)
    voltage := first.get --samples=129
    expect (0.0 <= voltage <= 3.3)
    first.close
    raw = second.get --raw
    expect (0 <= raw <= 4095)
  finally:
    first.close
    second.close

expect-oom [block]:
  error := catch block
  expect (error == "MALLOC_FAILED" or error == "ALLOCATION_FAILED" or error == "OUT_OF_MEMORY")

test-i2c:
  expect-oom:
    i2c.Target --sda=20 --scl=21 --address=0x42 --send-buffer-size=(1 << 30) --pull-up
  target := i2c.Target --sda=20 --scl=21 --address=0x42 --pull-up
  expect-throw "ALREADY_IN_USE": gpio.Pin 20 --input
  target.close
  target.close
  registers := i2c.RegisterTarget --sda=20 --scl=21 --address=0x42 --pull-up
  registers.close
  bus := i2c.Bus --sda=20 --scl=21 --frequency=100_000 --pull-up
  child := bus.device 0x42
  try:
    // No target is attached: require a NACK, not a hung peripheral.
    error := catch: child.read 1
    expect-equals "I2C_NACK" error
  finally:
    bus.close
  expect-throw "CLOSED": child.write #[0]
  child.close

test-spi:
  expect-oom:
    spi.BufferTarget
        --mosi=20
        --clock=18
        --cs=21
        --mode=1
        --buffer-size=16
        --receive-queue-depth=(1 << 20)
  buffered := spi.BufferTarget --mosi=20 --clock=18 --cs=21 --mode=1 --buffer-size=16
  buffered.close
  target := spi.Target --mosi=20 --clock=18 --cs=21 --mode=1 --max-transfer-size=64
  expect-throw "ALREADY_IN_USE": gpio.Pin 20 --input
  target.close
  target.close
  bus := spi.Bus --mosi=19 --miso=20 --clock=18
  try:
    4.repeat: | mode/int |
      device := bus.device --cs=21 --frequency=1_000_000 --mode=mode
      try:
        device.write (ByteArray 1024 --initial=0x55)
        expect-equals 1024 (device.read 1024).size
      finally:
        device.close
  finally:
    bus.close
