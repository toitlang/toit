// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ec618 show Ec618
import expect show *
import monitor
import spi

import .framed-control show FramedChannel
import .wiring as wiring

pattern size/int seed/int -> ByteArray:
  return ByteArray size: (it * 31 + seed) & 0xff

exchange control/FramedChannel command/string expected/string="OK":
  control.send command
  expect-equals expected (control.receive --timeout-ms=15_000)

main args:
  mode := args.is-empty ? "all" : args[0]
  uart := Ec618.uart1 --baud-rate=115200
  control := FramedChannel uart
  try:
    exchange control "PING" "READY"
    if mode == "all" or mode == "i2c": test-i2c control
    if mode == "i2c0": test-i2c0 control
    if mode == "all" or mode == "speed": test-speed control
    if mode == "all" or mode == "stretch": test-stretch control
    if mode == "all" or mode == "spi": test-spi control
    exchange control "QUIT"
    print "bus-controller-ec618: PASS"
  finally:
    uart.close

test-i2c0 control/FramedChannel:
  bus := Ec618.i2c0 --pull-up
  try:
    [50_000, 100_000, 400_000].do: | frequency/int |
      device := bus.device 0x42 --frequency=frequency
      try:
        [1, 4, 16, 32].do: | size/int |
          exchange control "I2C0-ARM $size" "READY"
          expect (bus.test 0x42)
          expect (not (bus.test 0x43))
          with-timeout --ms=2_000:
            expect-equals (pattern size 7) (device.read size)
          exchange control "I2C0-ARM $size" "READY"
          with-timeout --ms=2_000:
            expect-equals (pattern size 7) (device.write-read #[0, 0] size)
          exchange control "I2C0-CHECK 0"
          print "I2C0 $frequency read/write-read $size PASS"
        [1, 32, 512, 513, 1025].do: | size/int |
          exchange control "I2C0-ARM 1" "READY"
          with-timeout --ms=2_000: device.write (pattern size 23)
          exchange control "I2C0-CHECK $size"
          print "I2C0 $frequency write $size PASS"
      finally:
        device.close
    exchange control "I2C-CLOSE"
  finally:
    bus.close

test-i2c control/FramedChannel --controller/int=1:
  exchange control "I2C-REG" "READY"
  bus := controller == 0 ? (Ec618.i2c0 --pull-up) : (Ec618.i2c1 --pull-up)
  try:
    expect-throw "UNIMPLEMENTED": bus.device 0x42 --timeout-us=1_000
    expect (bus.test 0x42) --message="known I2C target must ACK address-only probe"
    expect (not (bus.test 0x43 --timeout-ms=20)) --message="absent I2C target must NACK probe"
    [100_000, 400_000, 50_000].do: | frequency/int |
      device := bus.device 0x42 --frequency=frequency
      try:
        [1, 4, 16, 32, 63, 64, 65, 511, 512, 513, 1024, 1025].do: | size/int |
          with-timeout --ms=5_000:
            if size > 512: print "I2C $size combined read"
            expect-equals (pattern size 7) (device.write-read #[0, 0] size)
            if size > 512: print "I2C $size separate read"
            device.write #[0, 0]
            buffer := ByteArray (size + 5) --initial=0xee
            device.read-into buffer size
            expect-equals (pattern size 7) (buffer[..size])
            expect-equals (ByteArray 5 --initial=0xee) (buffer[size..])
            if size > 512: print "I2C $size write"
            device.write (#[0, 0] + (pattern size 23))
          exchange control "I2C-CHECK $size"
          print "I2C $frequency $size PASS"
        expect-throw "I2C_NACK":
          missing := bus.device 0x43
          try:
            missing.write #[1]
          finally:
            missing.close
        expect-equals #[7] (device.write-read #[0, 0] 1)
      finally:
        device.close
  finally:
    bus.close
    exchange control "I2C-CLOSE"

test-spi control/FramedChannel:
  bus := spi.Bus
      --mosi=wiring.EC618-SPI0-MOSI-PAD
      --miso=wiring.EC618-SPI0-MISO-PAD
      --clock=wiring.EC618-SPI0-CLK-PAD
  try:
    duplicate-error := catch:
      spi.Bus
          --mosi=wiring.EC618-SPI0-MOSI-PAD
          --miso=wiring.EC618-SPI0-MISO-PAD
          --clock=wiring.EC618-SPI0-CLK-PAD
    expect-equals "ALREADY_IN_USE" duplicate-error
    // Reuse the large payload so repeated DMA checks do not fragment the
    // small native heap with differently sized external byte arrays.
    buffer := ByteArray (32768 + 4)
    test-spi-cancellation control bus buffer
    4.repeat: | mode/int |
      [0, 1, 3].do: | prefix/int |
        device := bus.device
            --cs=wiring.EC618-SPI0-CS-PAD
            --frequency=1_000_000
            --mode=mode
            --command-bits=(prefix == 1 ? 4 : (prefix == 3 ? 8 : 0))
            --address-bits=(prefix == 1 ? 4 : (prefix == 3 ? 16 : 0))
        try:
          [1, 4, 16, 32, 63, 64, 65, 511, 512, 513, 1025, 4092, 8193, 32768].do: | size/int |
            exchange control "SPI $(size + prefix) $mode $prefix" "READY"
            buffer.size.repeat: buffer[it] = 0xee
            size.repeat: buffer[it + 2] = (it * 31 + 23) & 0xff
            with-timeout --ms=5_000:
              // A zero-valued four-bit command still occupies its prefix
              // bits; the following four-bit address must not move left.
              device.transfer buffer --from=2 --to=(size + 2) --read
                  --command=(prefix == 1 ? 0 : 0xa5)
                  --address=(prefix == 1 ? 0xb : 0x1234)
            expect-equals #[0xee, 0xee] (buffer[..2])
            expect-equals #[0xee, 0xee] (buffer[size + 2..size + 4])
            mismatch := -1
            size.repeat:
              expected := ((it + prefix) * 31 + 7) & 0xff
              if mismatch < 0 and expected != buffer[it + 2]: mismatch = it
            exchange control "SPI-DONE"
            if mismatch >= 0:
              expected := ((mismatch + prefix) * 31 + 7) & 0xff
              print "SPI mismatch expected=$expected got=$(buffer[mismatch + 2])"
            expect (mismatch < 0) --message="SPI mode=$mode prefix=$prefix size=$size first mismatch=$mismatch"
            print "SPI mode=$mode prefix=$prefix size=$size PASS"
        finally:
          device.close
  finally:
    bus.close

test-spi-cancellation control/FramedChannel bus/spi.Bus payload/ByteArray:
  canceled := bus.device --cs=wiring.EC618-SPI0-CS-PAD --frequency=100_000
  try:
    32768.repeat: payload[it] = (it * 31 + 23) & 0xff
    exchange control "SPI-CANCEL 32768 0 0" "READY"
    started := Time.monotonic-us
    expect-throw DEADLINE-EXCEEDED-ERROR:
      with-timeout --ms=20: canceled.transfer payload --to=32768 --read
    elapsed := Time.monotonic-us - started
    print "SPI cancellation: $elapsed us"
    expect (elapsed < 150_000) --message="SPI cancellation must promptly retire DMA"
    exchange control "SPI-DONE"
    exchange control "SPI 4 0 0" "READY"
    bytes := pattern 4 23
    canceled.transfer bytes --read
    expect-equals (pattern 4 7) bytes
    exchange control "SPI-DONE"
  finally:
    canceled.close

test-stretch control/FramedChannel:
  bus := Ec618.i2c1 --pull-up
  device := bus.device 0x42 --frequency=100_000
  try:
    exchange control "I2C-STRETCH 20" "READY"
    started := Time.monotonic-us
    with-timeout --ms=1_000: expect-equals #[0xa5] (device.read 1)
    expect (Time.monotonic-us - started >= 15_000)
    exchange control "I2C-CLOSE"
    exchange control "I2C-STRETCH 200" "READY"
    expect-throw DEADLINE-EXCEEDED-ERROR:
      with-timeout --ms=20: device.read 1
    exchange control "I2C-CLOSE"
    exchange control "I2C-REG" "READY"
    with-timeout --ms=1_000:
      expect-equals #[7] (device.write-read #[0, 0] 1)
    exchange control "I2C-CLOSE"
    print "I2C stretch and cancellation PASS"
  finally:
    bus.close

test-speed control/FramedChannel:
  exchange control "I2C-REG" "READY"
  bus := Ec618.i2c1 --pull-up
  durations := []
  expected := pattern 1025 7
  try:
    [50_000, 100_000, 200_000, 330_000, 400_000, 1_000_000, 50_000].do: | frequency/int |
      device := bus.device 0x42 --frequency=frequency
      elapsed := 0
      try:
        3.repeat:
          // Probes always use 50 kHz. The next transfer must restore the
          // device's requested frequency rather than inheriting probe pace.
          expect (bus.test 0x42)
          started := Time.monotonic-us
          received := with-timeout --ms=2_000: device.write-read #[0, 0] expected.size
          elapsed += Time.monotonic-us - started
          expect-equals expected received
      finally:
        device.close
      durations.add elapsed
      print "I2C speed $frequency: $elapsed us"
    expect (durations[0] > durations[1] * 1.5)
    expect (durations[1] > durations[2] * 1.5)
    expect (durations[2] > durations[3] * 1.2)
    expect (durations[4] < durations[3] * 1.2)
    expect ((durations[4] - durations[5]).abs < durations[4] / 4)
    expect ((durations[6] - durations[0]).abs < durations[0] / 4)
  finally:
    bus.close
    exchange control "I2C-CLOSE"
