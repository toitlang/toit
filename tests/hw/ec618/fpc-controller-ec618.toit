// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the license in tests/LICENSE.

import ec618 show Ec618
import expect show *
import gpio
import i2c
import monitor

import .fpc-stream show *
import .framed-control show FramedChannel
import .wiring as wiring

exchange control/FramedChannel command/string expected/string="OK":
  control.send command
  expect-equals expected (control.receive --timeout-ms=25_000)

main args:
  mode := args.is-empty ? "" : args[0]
  if not ["dual-i2c-matrix", "uart", "uart-alt", "spi"].contains mode:
    throw "Unknown FPC bus test: $mode"
  port := Ec618.uart1 --baud-rate=115200
  control := FramedChannel port
  try:
    exchange control "PING" "READY"
    if mode == "dual-i2c-matrix":
      // Keep PAD19/GPIO1 idle while a DS18B20 is connected there.
      [50_000, 100_000, 400_000].do: |frequency/int|
        [1, 31, 32, 33, 65, 129, 513].do: |size/int|
          test-dual-i2c control --frequency=frequency --size=size
    else if mode == "uart": test-uart control --mapping=1
    else if mode == "uart-alt": test-uart control --mapping=2
    else if mode == "spi": test-spi control
    exchange control "QUIT"
    print "FPC-FUNCTION $mode PASS"
  finally:
    port.close

test-dual-i2c control/FramedChannel --frequency/int --size/int:
  exchange control "I2C-OPEN 0" "READY"
  exchange control "I2C-OPEN 1 old" "READY"
  bus0 := i2c.Bus --sda=wiring.EC618-FPC-I2C0-SDA-PAD --scl=wiring.EC618-FPC-I2C0-SCL-PAD --pull-up
  bus1 := i2c.Bus --sda=wiring.EC618-I2C1-SDA-PAD --scl=wiring.EC618-I2C1-SCL-PAD --pull-up
  iterations := 50
  try:
    finished := [monitor.Latch, monitor.Latch]
    buses := [bus0, bus1]
    2.repeat: |id|
      print "DUAL-I2C sequential controller $id begin"
      device := buses[id].device 0x42 --frequency=frequency
      try:
        with-timeout --ms=3000:
          expect-equals (pattern size (7 + id)) (device.write-read #[0, 0] size)
        print "DUAL-I2C sequential controller $id PASS"
      finally:
        device.close
    2.repeat: |id|
      task::
        error := catch:
          device := buses[id].device 0x42 --frequency=frequency
          try:
            iterations.repeat: |iteration|
              with-timeout --ms=3000:
                received := device.write-read #[0, 0] size
                if received != (pattern size (7 + id)):
                  throw "I2C$id iteration=$iteration corrupt data: $received"
          finally:
            device.close
        finished[id].set error
    errors := finished.map: it.get
    errors.do: if it: throw it
    print "I2C0 + I2C1: $iterations reads each size=$size frequency=$frequency PASS"
  finally:
    bus0.close
    bus1.close
    exchange control "I2C-CLOSE"

test-uart control/FramedChannel --mapping/int:
  pads := mapping == 2
      ? [wiring.EC618-FPC-UART2-ALT-TX-PAD, wiring.EC618-FPC-UART2-ALT-RX-PAD]
      : [28, wiring.EC618-FPC-UART2-RX-PAD]
  [115200, 921600, 2000000, 3000000].do: |baud/int|
    exchange control "UART-OPEN $baud $mapping" "READY"
    port := Ec618.uart2 --mapping=mapping --baud-rate=baud --large-buffers
    try:
      pads.do: |pad/int|
        expect-throw "ALREADY_IN_USE":
          pin := gpio.Pin pad --input
          pin.close
      print "UART2 mapping=$mapping $baud baud starting duplex transfer"
      exchange control "UART-ARM 65536" "READY"
      error := catch:
        with-timeout --ms=30_000:
          Task.group [
            :: receive-stream port 65536 7,
            ::
              exchange control "UART-GO 65536"
              send-stream port 65536 23,
          ]
      if error: throw error
      exchange control "UART-DONE"
      expect-equals 0 port.errors
      print "UART2 mapping=$mapping $baud baud 65536 bytes each direction PASS"
    finally:
      port.close
      exchange control "UART-CLOSE"

test-spi control/FramedChannel:
  bus := Ec618.spi0
  try:
    4.repeat: |mode|
      [100_000, 1_000_000].do: |hz/int|
        cs := wiring.EC618-FPC-SPI0-CS-PAD
        device := bus.device --cs=cs --frequency=hz --mode=mode
        try:
          [1, 64, 513, 4096, 8193].do: |size/int|
            exchange control "SPI $size $mode $wiring.S3-FPC-SPI0-CS-PIN" "READY"
            bytes := pattern size 23
            with-timeout --ms=5000: device.transfer bytes --read
            exchange control "SPI-DONE"
            expect-equals (pattern size 7) bytes
            print "SPI0 CS PAD$cs mode=$mode $hz Hz $size bytes PASS"
        finally:
          device.close
  finally:
    bus.close
