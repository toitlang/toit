// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Checks that the peripheral libraries accept an integer GPIO number (the new
// API), warn when given a (deprecated) gpio.Pin, and reject other types.

import gpio
import gpio.adc show Adc
import i2c
import rmt
import spi
import uart

main:
  pin := gpio.Pin 5

  // RMT.
  rmt.Out 18 --resolution=1_000_000      // OK.
  rmt.Out pin --resolution=1_000_000     // Warning: deprecated Pin.
  rmt.Out "x" --resolution=1_000_000     // Error: string.
  rmt.In 19 --resolution=1_000_000       // OK.
  rmt.In pin --resolution=1_000_000      // Warning: deprecated Pin.

  // I2C.
  i2c.Bus --sda=21 --scl=22              // OK.
  i2c.Bus --sda=pin --scl=22            // Warning: deprecated Pin for sda.
  i2c.Bus --sda=21 --scl=1.5            // Error: float for scl.

  // SPI (optional cs/dc).
  bus := spi.Bus --mosi=13 --miso=12 --clock=14   // OK.
  bus.device --cs=15 --frequency=1_000_000        // OK.
  bus.device --cs=pin --frequency=1_000_000       // Warning: deprecated Pin.
  bus.device --dc="x" --frequency=1_000_000       // Error: string for dc.

  // UART (optional tx/rx).
  uart.Port --tx=17 --rx=16 --baud-rate=115200    // OK.
  uart.Port --tx=pin --baud-rate=115200           // Warning: deprecated Pin.
  uart.Port --tx=1.5 --baud-rate=115200           // Error: float.

  // ADC (gpio sub-library; uses the unprefixed 'Pin' type).
  Adc 34                                 // OK.
  Adc pin                                // Warning: deprecated Pin.
  Adc "x"                                // Error: string.
