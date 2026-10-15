// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the license in tests/LICENSE.

import ec618 show Ec618
import expect show *
import gpio
import i2c
import i2s

import .wiring as wiring

// Peers must leave these nets idle. No transfers or I2S clocks are started.
main:
  check-ownership [wiring.EC618-FPC-I2C0-SDA-PAD, wiring.EC618-FPC-I2C0-SCL-PAD]::
    i2c.Bus --sda=wiring.EC618-FPC-I2C0-SDA-PAD --scl=wiring.EC618-FPC-I2C0-SCL-PAD --pull-up
  check-ownership [wiring.EC618-FPC-I2C1-SDA-PAD, wiring.EC618-FPC-I2C1-SCL-PAD]::
    i2c.Bus --sda=wiring.EC618-FPC-I2C1-SDA-PAD --scl=wiring.EC618-FPC-I2C1-SCL-PAD --pull-up
  check-ownership [28, wiring.EC618-FPC-UART2-RX-PAD]:: Ec618.uart2 --mapping=1 --baud-rate=115200
  check-ownership [wiring.EC618-FPC-UART2-ALT-TX-PAD, wiring.EC618-FPC-UART2-ALT-RX-PAD]::
    Ec618.uart2 --mapping=2 --baud-rate=115200
  check-ownership [wiring.EC618-I2S1-TX-PAD, wiring.EC618-I2S1-RX-PAD,
      wiring.EC618-I2S1-SCK-PAD, wiring.EC618-I2S1-WS-PAD]::
    i2s.Bus --no-master
        --tx=wiring.EC618-I2S1-TX-PAD
        --rx=wiring.EC618-I2S1-RX-PAD
        --sck=wiring.EC618-I2S1-SCK-PAD
        --ws=wiring.EC618-I2S1-WS-PAD
  print "FPC ownership PASS GPIO conflicts, failed-open cleanup and pad reuse"

check-ownership pads/List factory/Lambda:
  print "Ownership pads=$pads"
  pads.do: |pad/int|
    print "Ownership GPIO claim PAD$pad"
    pin := gpio.Pin pad --input
    try:
      print "Ownership conflicting peripheral open PAD$pad"
      expect-throw "ALREADY_IN_USE":
        unexpected := factory.call
        unexpected.close
    finally:
      pin.close
    // Every failed open must release earlier pads and controller reservations.
    print "Ownership peripheral reopen PAD$pad"
    peripheral := factory.call
    try:
      pads.do: |owned/int|
        expect-throw "ALREADY_IN_USE":
          unexpected := gpio.Pin owned --input
          unexpected.close
    finally:
      print "Ownership peripheral close PAD$pad"
      peripheral.close
    pads.do: |released/int|
      available := gpio.Pin released --input
      available.close
