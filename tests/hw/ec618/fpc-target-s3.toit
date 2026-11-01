// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the license in tests/LICENSE.

import expect show *
import i2c
import monitor
import spi
import uart

import .fpc-stream show *
import .wiring as wiring

reply value: print "BUS-REPLY $value"

main:
  console := uart.Port.console
  targets := [null, null]
  port/uart.Port? := null
  spi-target/spi.Target? := null
  work/Task? := null
  received/monitor.Latch? := null
  sent/monitor.Latch? := null
  completed/monitor.Latch? := null
  try:
    while line := console.in.read-line:
      parts := line.split " "
      cmd := parts[0]
      if cmd == "PING":
        reply "READY"
      else if cmd == "IDENTIFY":
        reply "FPC-BUS-1"
      else if cmd == "I2C-OPEN":
        id := int.parse parts[1]
        old-pads := parts.size > 2 and parts[2] == "old"
        classic := parts.size > 2 and parts[2] == "classic"
        target := i2c.RegisterTarget
            --sda=(classic ? (id == 0 ? wiring.S3-SPI0-MISO-PIN : wiring.S3-I2C1-SDA-PIN) : (id == 0 ? wiring.S3-FPC-I2C0-SDA-PIN : (old-pads ? wiring.S3-I2C1-SDA-PIN : wiring.S3-FPC-I2C1-SDA-PIN)))
            --scl=(classic ? (id == 0 ? wiring.S3-SPI0-CLK-PIN : wiring.S3-I2C1-SCL-PIN) : (id == 0 ? wiring.S3-FPC-I2C0-SCL-PIN : (old-pads ? wiring.S3-I2C1-SCL-PIN : wiring.S3-FPC-I2C1-SCL-PIN)))
            --address=0x42
            --register-count=4096
            --register-address-byte-size=2
            --receive-buffer-size=4096
            --pull-up
        targets[id] = target
        target.write 0 (pattern 4096 (7 + id))
        reply "READY"
      else if cmd == "I2C-CHECK":
        id := int.parse parts[1]
        size := int.parse parts[2]
        target/i2c.RegisterTarget := targets[id]
        expect-equals (pattern size (23 + id)) (target.read 0 size)
        expect-equals 0 target.dropped-write-count
        target.write 0 (pattern 4096 (7 + id))
        reply "OK"
      else if cmd == "I2C-CLOSE":
        targets.size.repeat:
          if targets[it]:
            targets[it].close
            targets[it] = null
        reply "OK"
      else if cmd == "UART-OPEN":
        mapping := parts.size > 2 ? (int.parse parts[2]) : 1
        if mapping < 0 or mapping > 2: throw "Unknown UART mapping: $mapping"
        tx := [wiring.S3-SPI0-MISO-PIN, wiring.S3-FPC-UART2-TX-PIN, wiring.S3-FPC-UART2-ALT-TX-PIN][mapping]
        rx := [wiring.S3-SPI0-CLK-PIN, wiring.S3-FPC-UART2-RX-PIN, wiring.S3-FPC-UART2-ALT-RX-PIN][mapping]
        port = uart.Port --tx=tx --rx=rx
            --baud-rate=(int.parse parts[1])
            --large-buffers
        reply "READY"
      else if cmd == "UART-ARM":
        n := int.parse parts[1]
        received = monitor.Latch
        sent = monitor.Latch
        work = task:: received.set (catch: receive-stream port n 23)
        reply "READY"
      else if cmd == "UART-GO":
        n := int.parse parts[1]
        task:: sent.set (catch: send-stream port n 7)
        reply "OK"
      else if cmd == "UART-DONE":
        rx-error := received.get
        tx-error := sent.get
        work = null
        reply (rx-error or tx-error or port.errors != 0
            ? "ERROR rx=$rx-error tx=$tx-error uart-errors=$port.errors"
            : "OK")
      else if cmd == "UART-CLOSE":
        port.close
        port = null
        reply "OK"
      else if cmd == "SPI":
        n := int.parse parts[1]
        mode := int.parse parts[2]
        cs := parts.size > 3 ? (int.parse parts[3]) : wiring.S3-FPC-SPI0-CS-PIN
        spi-target = spi.Target --cs=cs --clock=wiring.S3-SPI0-CLK-PIN
            --mosi=wiring.S3-SPI0-MOSI-PIN
            --miso=wiring.S3-SPI0-MISO-PIN
            --mode=mode
            --max-transfer-size=n
        completed = monitor.Latch
        work = task::
          error := catch:
            got := spi-target.transfer (pattern n 7) --receive-size=n
                --when-armed=(: reply "READY")
            if got.size != n: throw "SPI length expected=$n got=$got.size"
            n.repeat:
              expected := (it * 31 + 23) & 0xff
              if got[it] != expected:
                throw "SPI mismatch at $it expected=$expected got=$got[it]"
          completed.set error
      else if cmd == "SPI-DONE":
        error := completed.get
        spi-target.close
        spi-target = null
        work = null
        reply (error ? "ERROR $error" : "OK")
      else if cmd == "QUIT":
        reply "OK"
        return
      else:
        throw "Unknown command: $line"
  finally:
    if work: work.cancel
    if port: port.close
    if spi-target: spi-target.close
    targets.do: if it: it.close
