// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.
import gpio
import i2c
import expect show *

main:
  ack := gpio.Pin 33 --input --pull-down
  sequence := 0
  request := : | command/string |
    sequence++
    print "GPIO REQUEST $sequence $command"
    with-timeout --ms=5000: ack.wait-for (sequence & 1)
  bus := i2c.Bus --sda=34 --scl=35 --frequency=100000 --pull-up
  target := bus.device 0x42

  [1, 31, 32, 33, 255, 256, 257, 1024, 4096].do: | size |
    request.call "I2C_QUEUE 21 22 $size"
    buffer := ByteArray (size + 8) --initial=0xa5
    target.read-into buffer size
    size.repeat: | i | expect-equals ((i * 73 + 7) & 0xff) buffer[i]
    8.repeat: | i | expect-equals 0xa5 buffer[size + i]
    request.call "I2C_CLOSE"

    request.call "I2C_QUEUE 21 22 $size"
    expect-equals (pattern size 7) (target.write-read (pattern 17 23) size)
    request.call "I2C_CHECK 17"
    request.call "I2C_CLOSE"
    print "I2C queued read and repeated START $size PASS"

  request.call "I2C_QUEUE 21 22 4096"
  ticks := 0
  ticker := task::
    while true:
      ticks++
      sleep --ms=5
  expect-equals (pattern 4096 7) (target.read 4096)
  ticker.cancel
  expect ticks >= 10
  request.call "I2C_CLOSE"
  print "I2C large read leaves VM runnable PASS"

  request.call "I2C_QUEUE 21 22 4096"
  buffer := ByteArray 4096 --initial=0xa5
  expect-equals DEADLINE-EXCEEDED-ERROR (catch:
    with-timeout --ms=2: target.read-into buffer)
  expect-equals (ByteArray 4096 --initial=0xa5) buffer
  request.call "I2C_CLOSE"
  request.call "I2C_QUEUE 21 22 257"
  expect-equals (pattern 257 7) (target.read 257)
  request.call "I2C_CLOSE"
  print "I2C cancelled read preserves destination and allows reuse PASS"

  bus.close
  ack.close
  print "NRF5340 I2C READ PASS"

pattern size/int seed/int -> ByteArray:
  return ByteArray size: (it * 73 + seed) & 0xff
