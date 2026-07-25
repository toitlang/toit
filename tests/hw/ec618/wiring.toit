// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Physical wiring of the `modest-affair` EC618/ESP32 hardware-test rig.

Constants are named by hardware signal, not by the test that happens to use
  them. EC618 digital pin values are physical PAD indices; ESP32 values are
  GPIO numbers.
*/

// Analog staircase: each ESP32 DAC reaches one dedicated EC618 AIO input
// through the rig's voltage divider.
EC618-ADC0-CHANNEL ::= 0  // AIO3, dev-board contact 3.
EC618-ADC1-CHANNEL ::= 1  // AIO4, dev-board contact 4.
ESP32-ADC0-DAC-PIN ::= 25
ESP32-ADC1-DAC-PIN ::= 26

// UART1 is the usual control lane on the peripheral rig.
EC618-UART1-TX-PAD ::= 34
EC618-UART1-RX-PAD ::= 33
ESP32-UART1-RX-PIN ::= 4
ESP32-UART1-TX-PIN ::= 16

// UART2 is the usual data lane. Its wires are shared with SPI0 and GPIO.
EC618-UART2-TX-PAD ::= 26
EC618-UART2-RX-PAD ::= 25
ESP32-UART2-RX-PIN ::= 27
ESP32-UART2-TX-PIN ::= 14
ESP32-UART2-RX-NET-PINS ::= [27, 21]
ESP32-UART2-TX-NET-PINS ::= [14, 32]

// UART2 RS485 direction and the open-drain regression share the PAD33 wire.
EC618-UART2-DIRECTION-PAD ::= 33
ESP32-UART2-DIRECTION-PIN ::= 16
EC618-OPEN-DRAIN-BUS-PAD ::= 33
ESP32-OPEN-DRAIN-BUS-PIN ::= 16

// SPI0 / MFRC522. RST shares the TIMER0/PAD16 wire.
EC618-SPI0-CS-PAD ::= 23
EC618-SPI0-MOSI-PAD ::= 24
EC618-SPI0-MISO-PAD ::= 25
EC618-SPI0-CLK-PAD ::= 26
EC618-RC522-RST-PAD ::= 16
ESP32-SPI0-CS-PIN ::= 33
ESP32-SPI0-MOSI-PIN ::= 22
ESP32-SPI0-MISO-PIN ::= 14
ESP32-SPI0-CLK-PIN ::= 27
ESP32-RC522-RST-PIN ::= 23

// I2C1 / BMP280. ESP32 IO13 switches sensor power and is also wired to PAD42.
EC618-I2C1-SDA-PAD ::= 23
EC618-I2C1-SCL-PAD ::= 24
ESP32-I2C1-SDA-PIN ::= 33
ESP32-I2C1-SCL-PIN ::= 22
ESP32-SENSOR-POWER-PIN ::= 13

// I2C0 passive observation wires.
EC618-I2C0-SDA-PAD ::= 14
EC618-I2C0-SCL-PAD ::= 13
ESP32-I2C0-SDA-PIN ::= 18
ESP32-I2C0-SCL-PIN ::= 17

// Plain GPIO and wakeup nets.
EC618-GPIO10-NUM ::= 10
EC618-GPIO10-PAD ::= 25
ESP32-GPIO10-ADC-PINS ::= [32, 14]
EC618-GPIO11-NUM ::= 11
EC618-GPIO11-PAD ::= 26
ESP32-GPIO11-PIN ::= 27
EC618-GPIO22-NUM ::= 22
EC618-GPIO22-PAD ::= 42
ESP32-GPIO22-PIN ::= 13
EC618-GPIO24-NUM ::= 24
EC618-GPIO24-PAD ::= 44
ESP32-GPIO24-PIN ::= 19
EC618-GPIO27-NUM ::= 27
EC618-GPIO27-PAD ::= 47
ESP32-GPIO27-PIN ::= 2

// Alternate-pad GPIO coverage.
EC618-GPIO14-ALT-PAD ::= 13
ESP32-GPIO14-ALT-PIN ::= 17
EC618-GPIO15-ALT-PAD ::= 14
ESP32-GPIO15-ALT-PIN ::= 18

// Safe ESP32 inputs physically connected to EC618 GPIO-capable pads.
ESP32-GPIO-OBSERVATION-PINS ::= [27, 21, 14, 16, 4, 13, 33, 32, 23, 22, 19, 18, 17, 2]

// Every distinct GPIO-capable dev-board net:
//   [EC618 PAD, direct ESP32 GPIOs, optional observed coupled GPIOs].
// The duplicated GPIO10/GPIO11 board contacts are the same physical nets, so
// PAD25 and PAD26 each intentionally have two ESP32 observers.
// The powered BMP280 fixture couples SDA/SCL/power transitions; the third
// element on PAD23/PAD24 records that observed cluster without claiming extra
// direct wires.
GPIO-TEST-WIRES ::= [
  [26, ESP32-UART2-RX-NET-PINS],
  [25, ESP32-UART2-TX-NET-PINS],
  [42, [13]],
  [23, [33], [13, 33, 22]],
  [16, [23]],
  [24, [22], [13, 33, 22]],
  [44, [19]],
  [14, [18]],
  [13, [17]],
  [47, [2]],
  [34, [4]],
  [33, [16]],
]

// Dev-board nets used for programmable pull verification.
EC618-GPIO-PULL-DOWN-TEST-PAD ::= 42
EC618-GPIO-PULL-UP-TEST-PAD ::= 34

// PWM observation nets.
EC618-TIMER0-PAD ::= 16
ESP32-TIMER0-PIN ::= 23
EC618-TIMER1-PAD ::= 44
ESP32-TIMER1-PIN ::= 19
EC618-TIMER4-PAD ::= 33
ESP32-TIMER4-PIN ::= 16
EC618-TIMER4-AON-PAD ::= 47
ESP32-TIMER4-AON-PIN ::= 2
