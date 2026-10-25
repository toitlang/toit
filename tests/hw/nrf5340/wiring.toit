// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// [Signal name, nRF port, nRF pin, ESP32 GPIO]. Header numbers follow Ebyte's schematic.
WIRES ::= [
  ["gpio-a", 1, 0, 13],       // P3/20.
  ["gpio-b", 1, 1, 27],       // P3/22.
  ["uart-tx", 1, 4, 32],      // P2/11: nRF TX to ESP RX.
  ["uart-rx", 1, 5, 33],      // P2/4: nRF RX from ESP TX.
  ["i2c-sda", 1, 2, 21],      // P2/27. Internal pull-ups only on the present rig.
  ["i2c-scl", 1, 3, 22],      // P2/25. High-speed I2C qualification is deferred.
  ["spi-clock", 0, 8, 18],    // P2/22.
  ["spi-mosi", 0, 9, 23],     // P2/17.
  ["spi-miso", 0, 10, 19],    // P2/18.
  ["spi-cs", 0, 11, 4],       // P2/15.
  ["adc-ain0", 0, 4, 25],     // P3/26: ESP DAC1.
  ["adc-ain1", 0, 5, 26],     // P3/18: ESP DAC2.
]
