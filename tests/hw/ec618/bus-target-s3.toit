// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import i2c
import monitor
import spi
import uart

import .wiring as wiring

pattern size/int seed/int -> ByteArray:
  return ByteArray size: (it * 31 + seed) & 0xff

reply value:
  print "BUS-REPLY $value"

main:
  serve --sda=wiring.S3-I2C1-SDA-PIN --scl=wiring.S3-I2C1-SCL-PIN --spi-enabled

serve --sda/int --scl/int --spi-enabled/bool=false:
  console := uart.Port.console
  registers/i2c.RegisterTarget? := null
  i2c-target/i2c.Target? := null
  responder/Task? := null
  responder-done/monitor.Latch? := null
  target/spi.Target? := null
  completed/monitor.Latch? := null
  try:
    while line := console.in.read-line:
      parts := line.split " "
      command := parts[0]
      if command == "PING":
        reply "READY"
      else if command == "I2C-REG":
        registers = i2c.RegisterTarget
            --sda=sda
            --scl=scl
            --address=0x42
            --register-count=4096
            --register-address-byte-size=2
            --receive-buffer-size=4096
            --pull-up
        registers.write 0 (pattern 4096 7)
        reply "READY"
      else if command == "I2C-CHECK":
        size := int.parse parts[1]
        expect-equals (pattern size 23) (registers.read 0 size)
        expect-equals 0 registers.dropped-write-count
        registers.write 0 (pattern 4096 7)
        reply "OK"
      else if command == "I2C-STRETCH":
        delay := int.parse parts[1]
        i2c-target = i2c.Target
            --sda=sda
            --scl=scl
            --address=0x42
            --pull-up
        responder-done = monitor.Latch
        responder = task::
          try:
            i2c-target.serve-read-requests --response-timeout-us=2_000_000:
              sleep --ms=delay
              #[0xa5]
          finally:
            responder-done.set true
        // Let the responder enter its native request wait before READY.
        sleep --ms=1
        reply "READY"
      else if command == "I2C-CLOSE":
        if responder:
          responder.cancel
          responder-done.get
          responder = null
        if i2c-target:
          i2c-target.close
          i2c-target = null
        if registers:
          registers.close
          registers = null
        reply "OK"
      else if command == "SPI" or command == "SPI-CANCEL":
        expect spi-enabled
        size := int.parse parts[1]
        mode := int.parse parts[2]
        prefix := int.parse parts[3]
        target = spi.Target
            --cs=wiring.S3-SPI0-CS-PIN
            --clock=wiring.S3-SPI0-CLK-PIN
            --mosi=wiring.S3-SPI0-MOSI-PIN
            --miso=wiring.S3-SPI0-MISO-PIN
            --mode=mode
            --max-transfer-size=size
        completed = monitor.Latch
        task::
          error := catch:
            received := target.transfer (pattern size 7) --receive-size=size --when-armed=(: reply "READY")
            expected-size := command == "SPI-CANCEL" ? received.size : size
            if command == "SPI-CANCEL": expect (0 < received.size < size)
            expected := pattern (expected-size - prefix) 23
            if prefix == 1: expected = #[0x0b] + expected
            if prefix == 3: expected = #[0xa5, 0x12, 0x34] + expected
            expect-equals expected received
          completed.set error
      else if command == "SPI-DONE":
        error := completed.get
        target.close
        target = null
        if error: throw error
        reply "OK"
      else if command == "QUIT":
        reply "OK"
        return
      else:
        throw "unknown target command: $line"
  finally:
    if responder:
      responder.cancel
      responder-done.get
    if i2c-target: i2c-target.close
    if target: target.close
    if registers: registers.close
