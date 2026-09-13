// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import i2c
import uart

import .bus-control-esp32 as bridge
import .bus-target-s3 as fixture
import .wiring as wiring

/**
Serves the basic I2C0 target on the classic ESP32 and forwards UART1 control.

The classic ESP32 supports queued/default responses but cannot implement
  RegisterTarget or response-time stretching. Each read gets a fresh target,
  avoiding prefetched response bytes left behind by an earlier short read.
*/
main:
  forwarding := task:: bridge.main
  console := uart.Port.console
  target/i2c.Target? := null
  try:
    while line := console.in.read-line:
      parts := line.split " "
      command := parts[0]
      if command == "PING":
        fixture.reply "READY"
      else if command == "I2C0-ARM":
        if target: target.close
        size := int.parse parts[1]
        target = i2c.Target
            --sda=wiring.ESP32-I2C0-SDA-PIN
            --scl=wiring.ESP32-I2C0-SCL-PIN
            --address=0x42
            --receive-buffer-size=4096
            --default-response=(fixture.pattern size 7)
            --pull-up
        fixture.reply "READY"
      else if command == "I2C0-CHECK":
        size := int.parse parts[1]
        expected := size == 0 ? #[0, 0] : (fixture.pattern size 23)
        expect-equals expected (with-timeout --ms=2_000: target.read)
        fixture.reply "OK"
      else if command == "I2C-CLOSE":
        target.close
        target = null
        fixture.reply "OK"
      else if command == "QUIT":
        // Keep the UART bridge alive until the host forwards this reply.
        // The coordinator closes its TCP connection after receiving it.
        fixture.reply "OK"
      else:
        throw "unexpected fixture command '$command'"
  finally:
    if target: target.close
    console.close
    forwarding.cancel
