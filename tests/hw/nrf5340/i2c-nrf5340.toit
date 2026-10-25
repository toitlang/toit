// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.
import gpio
import i2c
import uart
import expect show *
import monitor show Semaphore

main:
  ack := gpio.Pin 33 --input --pull-down
  sequence := 0
  request := : | command/string |
    sequence++
    print "GPIO REQUEST $sequence $command"
    with-timeout --ms=5000: ack.wait-for (sequence & 1)
  bus := i2c.Bus --sda=34 --scl=35 --frequency=100000 --pull-up
  expect-equals "ALREADY_IN_USE" (catch: gpio.Pin 34 --output)
  expect-equals "ALREADY_IN_USE" (catch: gpio.Pin 35 --input)
  expect-equals "ALREADY_IN_USE" (catch: i2c.Bus --sda=8 --scl=9 --pull-up)
  free-pin := gpio.Pin 8 --input
  free-pin.close
  expect-equals "INVALID_ARGUMENT" (catch: bus.device 0x42 --frequency=10000)
  expect-equals "UNIMPLEMENTED" (catch: bus.device 0x42 --timeout-us=1000)
  target := bus.device 0x42
  missing := bus.device 0x43

  request.call "I2C_OPEN 21 22 32"
  expect (bus.test 0x42)
  expect (not (bus.test 0x43))
  expect-equals {0x42} bus.scan
  expect-equals "I2C_NACK" (catch: missing.write #[23])
  expect-equals "I2C_NACK" (catch: missing.read 1)
  expect-equals (pattern 32 7) (target.read 32)
  request.call "I2C_CLOSE"
  print "I2C probes, scan, NACK and read PASS"

  [1, 17, 32, 255, 256, 257, 1024, 4096].do: | size |
    request.call "I2C_OPEN 21 22 17"
    expect-equals (pattern 17 7) (target.write-read (pattern size 23) 17)
    request.call "I2C_CHECK $size"
    request.call "I2C_CLOSE"
  print "I2C combined DMA transfers PASS"

  request.call "I2C_OPEN 21 22 17"
  ticks := 0
  ticker := task::
    while true:
      ticks++
      sleep --ms=5
  target.write (pattern 1024 23)
  ticker.cancel
  expect ticks >= 3
  request.call "I2C_CHECK 1024"
  request.call "I2C_CLOSE"
  print "I2C transfer leaves VM runnable PASS"

  request.call "I2C_OPEN 21 22 17"
  request.call "UART_OPEN 32 33 115200 1"
  port := uart.Port --tx=36 --rx=37 --baud-rate=115200
  done := Semaphore
  failure := null
  exchanges := 0
  serial-task := task::
    failure = catch:
      20.repeat:
        data := pattern 128 55
        port.out.write data --flush
        received := 0
        while received < data.size:
          chunk := port.in.read
          expect received + chunk.size <= data.size
          chunk.size.repeat: | i | expect-equals data[received + i] chunk[i]
          received += chunk.size
        exchanges++
    done.up
  with-timeout --ms=2000:
    target.write (pattern 4096 23)
    // At least one complete UART exchange must occur before I2C returns.
    expect exchanges > 0
    done.down
  if failure: throw failure
  expect-equals 0 port.errors
  serial-task.cancel
  port.close
  request.call "UART_CLOSE"
  request.call "I2C_CHECK 4096"
  request.call "I2C_CLOSE"
  print "I2C and UART concurrent transfers PASS"

  request.call "I2C_OPEN 21 22 17"
  expect-equals DEADLINE-EXCEEDED-ERROR (catch:
    with-timeout --ms=2: target.write (pattern 1024 23))
  // Cancellation retires the blocking Zephyr transaction. It does not promise
  // that bytes already on the bus are rolled back.
  request.call "I2C_CHECK 1024"
  expect-equals (pattern 17 7) (target.read 17)
  request.call "I2C_CLOSE"
  print "I2C cancellation and subsequent operation PASS"

  request.call "CONFIG 22 OUT 0"
  buffer := ByteArray 17 --initial=0xa5
  expect-equals "I2C_TIMEOUT" (catch:
    with-timeout --ms=2000: target.read-into buffer)
  expect-equals (ByteArray 17 --initial=0xa5) buffer
  expect-equals DEADLINE-EXCEEDED-ERROR (catch:
    with-timeout --ms=10: target.read 17)
  request.call "CONFIG 22 IN 0"
  request.call "I2C_OPEN 21 22 17"
  expect (bus.test 0x42)
  expect-equals (pattern 17 7) (target.read 17)
  request.call "I2C_CLOSE"
  print "I2C held-clock timeout, cancellation and recovery PASS"
  bus.close
  expect-equals "CLOSED" (catch: target.read 1)

  64.repeat: | cycle |
    alternate := cycle % 2 == 1
    sda := alternate ? 8 : 34
    scl := alternate ? 9 : 35
    partner-sda := alternate ? 18 : 21
    partner-scl := alternate ? 23 : 22
    bus = i2c.Bus --sda=sda --scl=scl --frequency=100000 --pull-up
    target = bus.device 0x42
    request.call "I2C_OPEN $partner-sda $partner-scl 17"
    expect-equals (pattern 17 7) (target.write-read (pattern 257 23) 17)
    request.call "I2C_CHECK 257"
    request.call "I2C_CLOSE"
    bus.close
    request.call "CONFIG $partner-sda DOWN 0"
    request.call "CONFIG $partner-scl DOWN 0"
    request.call "CHECK $partner-sda 0"
    request.call "CHECK $partner-scl 0"
  print "I2C 64 close and remap cycles PASS"

  // Leave a native transfer pending when the process exits. The host checks
  // its payload and released SDA after VM teardown.
  bus = i2c.Bus --sda=34 --scl=35 --frequency=100000 --pull-up
  target = bus.device 0x42
  request.call "I2C_OPEN 21 22 17"
  task:: target.write (pattern 1024 23)
  sleep --ms=2
  print "NRF5340 I2C PASS"
  ack.close

pattern size/int seed/int -> ByteArray:
  return ByteArray size: (it * 73 + seed) & 0xff
