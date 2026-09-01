// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ec618 show Ec618

/**
Checks that EC618 convenience peripherals release the PADs they reserve.

EC618 peripheral resources own their integer-addressed PADs directly. Each
  pair below reopens immediately after close, without relying on carrier
  `gpio.Pin` objects or garbage collection.
*/

main:
  uart := Ec618.uart1 --baud-rate=115200
  uart.close
  uart = Ec618.uart1 --baud-rate=115200
  uart.close
  print "convenience-pin-lifecycle: UART1 reopened"

  i2c := Ec618.i2c0 --pull-up
  i2c.close
  i2c = Ec618.i2c0 --pull-up
  i2c.close
  print "convenience-pin-lifecycle: I2C0 reopened"

  spi := Ec618.spi0
  spi.close
  spi = Ec618.spi0
  spi.close
  print "convenience-pin-lifecycle: SPI0 reopened"

  print "convenience-pin-lifecycle-ec618: PASS"
