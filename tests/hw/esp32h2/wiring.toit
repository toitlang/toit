// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system

H2-RX ::= 2
H2-TX ::= 5
HELPER-RX ::= 35
HELPER-TX ::= 27
GPIO-LINKS ::= {0: 12, 1: 14, 3: 26, 4: 32, 10: 13}
H2-ADC ::= 3
HELPER-DAC ::= 26
H2-PULL ::= 4
HELPER-PULL ::= 32
HELPER-BIAS ::= 33
H2-WAKE ::= 10
HELPER-WAKE ::= 13

// Connected to H2 GPIO13, which may be used by the low-frequency crystal.
HELPER-RESERVED ::= 25

// Local peripheral assignments. Tests share these wires sequentially.
// Resolve by physical board, independently of the current tester/testee role.
GPIO-PIN ::= local-pin_ 1
PWM-PIN ::= GPIO-PIN
PWM-SECOND-PIN ::= local-pin_ H2-PULL
UART-READY ::= local-pin_ H2-WAKE
SPI-CS ::= GPIO-PIN
SPI-CLOCK ::= PWM-SECOND-PIN
SPI-MOSI ::= local-pin_ H2-ADC
SPI-MISO ::= local-pin_ 0
I2C-SDA ::= SPI-CS
I2C-SCL ::= SPI-CLOCK
I2S-DATA ::= SPI-MOSI
I2S-CLOCK ::= GPIO-PIN
I2S-WORD-SELECT ::= PWM-SECOND-PIN

local-pin_ h2-pin/int -> int:
  return system.architecture == system.ARCHITECTURE-ESP32H2
      ? h2-pin
      : GPIO-LINKS[h2-pin]
