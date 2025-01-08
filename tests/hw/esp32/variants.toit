// Copyright (C) 2025 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system

interface Variant:
  static CURRENT/Variant ::= VARIANTS[system.architecture]

  /*
  ADC.

  The $adc-control-pin and $adc-v33-pin are connected through
    two resistors (each of the same value). At each connection
    point we have one of the adc pins. The $adc1-pin is closer to
    the 3.3V pin and the $adc2-pin is closer to the ground pin.
  */
  adc1-pin -> int
  adc2-pin -> int
  adc-control-pin -> int
  adc-v33-pin -> int

  /*
  Distinct service UUIDs for each ble test.
  */
  ble1-service -> string
  ble1-service2 -> string

  ble2-service -> string

  ble3-first-service -> string

  ble4-service -> string

  ble5-service -> string

  ble6-service -> string

  espnow-channel -> int
  espnow-password -> string

  /*
  I2C pins.

  On board 2.
  Typically, scl is yellow and sda is blue.
  */
  i2c-scl-pin -> int
  i2c-sda-pin -> int

  /*
  HC-SR04 pins.

  Since the HC-SR04 is a 5V device, the echo pin should not be connected
    directly to the ESP32. Instead, it should be connected through a voltage
    divider or an LED (or through a level shifter).
  */
  hc-sr04-trigger-pin -> int
  hc-sr04-echo-pin -> int

  /*
  DS18B20 pins.
  */
  ds18b20-pin -> int

  /*
  Open drain test pins.

  The $open-drain-test-pin is connected to the $open-drain-level-pin
    through a 330Ohm resistor.
  The $open-drain-test-pin and $open-drain-measure-pin are connected
    without any resistor.
  The $open-drain-test-pin or $open-drain-measure-pin is connected to GND
    through a 1MOhm resistor.
  */
  open-drain-test-pin -> int
  open-drain-level-pin -> int
  open-drain-measure-pin -> int

  /*
  GPIO pins.

  Connect $gpio-pin1 to $gpio-pin2 with a 330Ohm resistor.
  Set the $gpio-pin-restricted to a pin that is restricted.
  */
  gpio-pin1 -> int
  gpio-pin2 -> int
  gpio-pin-restricted -> int

  /*
  Unconnected pins.
  */
  unconnected-pin1 -> int
  unconnected-pin2 -> int
  unconnected-pin3 -> int

  /*
  I2C pullup test pins.

  Same as $open-drain-test-pin and $open-drain-level-pin.
  Also uses $uncconnected-pin1.
  */
  i2c-pullup-test-pin -> int
  i2c-pullup-other-pin -> int
  i2c-pullup-measure-pin -> int

  /*
  2 Pins that are connected between the two boards.

  The $connected-pin1 of board 1 is connected to the $connected-pin2 of board 2.
  The $connected-pin2 of board 1 is connected to the $connected-pin1 of board 2.

  Don't forget to connect the grounds as well.
  */
  connected-pin1 -> int
  connected-pin2 -> int

  /*
  Pulse counter pins.

  Connect $pulse-counter1-in1 to $pulse-counter1-out1 with a 330Ohm resistor.
  Connect $pulse-counter1-in2 to $pulse-counter1-out2 with a 330Ohm resistor.
  */
  pulse-counter1-in1 -> int
  pulse-counter1-out1 -> int

  pulse-counter1-in2 -> int
  pulse-counter1-out2 -> int

  pulse-counter-channel-count -> int

  /*
  PWM pins.

  Connect $pwm-in1 to $pwm-out1 with a 330Ohm resistor.
  Connect $pwm-in2 to $pwm-out2 with a 330Ohm resistor.
  */
  pwm-in1 -> int
  pwm-out1 -> int

  pwm-in2 -> int
  pwm-out2 -> int

  /*
  RMT pull-up test pins.

  Same as $open-drain-test-pin and $open-drain-level-pin.
  */
  rmt-drain-pullup-test-pin -> int
  rmt-drain-pullup-level-pin -> int
  rmt-drain-pullup-measure-pin -> int

  /*
  RMT many test pins.

  Connect $rmt-many-in1 to $rmt-many-test-out1 with a 330Ohm resistor.
  Connect $rmt-many-in2 to $rmt-many-test-out2 with a 330Ohm resistor.
  */
  rmt-many-in1 -> int
  rmt-many-out1 -> int

  rmt-many-in2 -> int
  rmt-many-out2 -> int

  /*
  RMT pins.

  Connect $rmt-pin1 to $rmt-pin2 with a 330Ohm resistor.
  Connect $rmt-pin2 to $rmt-pin3 with a 330Ohm resistor.
  */
  rmt-pin1 -> int
  rmt-pin2 -> int
  rmt-pin3 -> int

  /*
  SPI keep-active pins.

  Connect $spi-keep-active-cs-pin to $spi-keep-active-in-cs-pin with a 330Ohm resistor.
  */
  spi-keep-active-cs-pin -> int
  spi-keep-active-in-cs-pin -> int

  /*
  Touch pins.

  Connect a jumper wire to the touch pins. These should otherwise be
    unconnected.
  $touch-pin1 should be yellow.
  $touch-pin2 should be green.
  */
  touch-pin1 -> int
  touch-pin2 -> int

  /*
  Uart baud-rate pins.

  Connect uart-baud-rate-in1 to uart-baud-rate-out1 with a 330Ohm resistor.
  Connect uart-baud-rate-in2 to uart-baud-rate-out2 with a 330Ohm resistor.
  */
  uart-baud-rate-in1 -> int
  uart-baud-rate-out1 -> int

  uart-baud-rate-in2 -> int
  uart-baud-rate-out2 -> int

  /*
  Uart flush test pins.

  Connect uart-flush-in1 to uart-flush-out1 with a 330Ohm resistor.
  Connect uart-flush-in2 to uart-flush-out2 with a 330Ohm resistor.
  */
  uart-flush-in1 -> int
  uart-flush-out1 -> int

  uart-flush-in2 -> int
  uart-flush-out2 -> int

  /*
  Wait-for-close test pins.

  The $wait-for-close-pin should be connected to GND with an 1MOhm resistor.
  */
  wait-for-close-pin -> int

VARIANTS ::= {
  system.ARCHITECTURE-ESP32: Esp32,
  system.ARCHITECTURE-ESP32S3: Esp32s3,
}

abstract class VariantBase:
  abstract adc1-pin -> int
  abstract adc2-pin -> int
  abstract adc-v33-pin -> int

  abstract open-drain-test-pin -> int
  abstract open-drain-level-pin -> int
  abstract open-drain-measure-pin -> int
  abstract unconnected-pin1 -> int
  abstract pulse-counter1-in2 -> int
  abstract pulse-counter1-out2 -> int

  i2c-pullup-test-pin -> int: return open-drain-test-pin
  i2c-pullup-other-pin -> int: return unconnected-pin1
  i2c-pullup-measure-pin -> int: return open-drain-measure-pin

  gpio-pin1 -> int: return open-drain-test-pin
  gpio-pin2 -> int: return open-drain-level-pin

  pulse-counter1-in1 -> int: return open-drain-test-pin
  pulse-counter1-out1 -> int: return open-drain-level-pin

  pwm-in1 -> int: return pulse-counter1-in1
  pwm-out1 -> int: return pulse-counter1-out1

  pwm-in2 -> int: return pulse-counter1-in2
  pwm-out2 -> int: return pulse-counter1-out2

  rmt-drain-pullup-test-pin -> int: return open-drain-test-pin
  rmt-drain-pullup-level-pin -> int: return open-drain-level-pin
  rmt-drain-pullup-measure-pin -> int: return open-drain-measure-pin

  rmt-many-in1 -> int: return pulse-counter1-in1
  rmt-many-out1 -> int: return pulse-counter1-out1

  rmt-many-in2 -> int: return pulse-counter1-in2
  rmt-many-out2 -> int: return pulse-counter1-out2

  rmt-pin1 -> int: return adc1-pin
  rmt-pin2 -> int: return adc2-pin
  rmt-pin3 -> int: return adc-v33-pin

  spi-keep-active-cs-pin -> int: return open-drain-test-pin
  spi-keep-active-in-cs-pin -> int: return open-drain-level-pin

  uart-baud-rate-in1 -> int: return pulse-counter1-in1
  uart-baud-rate-out1 -> int: return pulse-counter1-out1

  uart-baud-rate-in2 -> int: return pulse-counter1-in2
  uart-baud-rate-out2 -> int: return pulse-counter1-out2

  uart-flush-in1 -> int: return pulse-counter1-in1
  uart-flush-out1 -> int: return pulse-counter1-out1

  uart-flush-in2 -> int: return pulse-counter1-in2
  uart-flush-out2 -> int: return pulse-counter1-out2

  wait-for-close-pin -> int: return open-drain-measure-pin

/*
A configuration for the ESP32.

On board 1 connect as follows:
- IO12 - IO14 with 330Ohm
- IO14 - IO32 with 330Ohm
- IO32 - IO25 with 330Ohm
- IO2 and IO4 should be connected to a jumper wire but floating.
- IO18 - IO34
- IO18 (or IO34) - GND with 1MOhm (or similar high number).
- IO18 - IO19 with 330Ohm
- IO26 - IO33
- IO21 - IO19 with 330Ohm

IO2, IO4, and IO16 must stay unconnected.

Connect board 1 to board 2 as follows:
- GND - GND
- IO22 - IO23
- IO23 - IO22

On board2:
- IO19 -> HC-SR04 Echo. Ideally through a voltage divider or an LED.
- IO18 -> HC-SR04 Trig
- IO14 -> DHT11 Data
- IO15 -> DS18B20 Data
- IO32 -> bme280 SCL (yellow)
- IO33 -> bme280 SDA (blue)

IO2, IO4, and IO16 must stay unconnected.
*/
class Esp32 extends VariantBase implements Variant:
  adc1-pin ::= 32
  adc2-pin ::= 14
  adc-control-pin ::= 25
  adc-v33-pin ::= 12

  ble1-service ::= "df451d2d-e899-4346-a8fd-bca9cbfebc0b"
  ble1-service2 ::= "94a11d6a-fa23-4a09-aa6f-2ca0b7cdbb70"

  ble2-service ::= "a1bcf0ba-7557-4968-91f8-6b0f187af2b5"

  ble3-first-service ::= "ffe21239-d8a2-4536-b751-0881a9f2e3de"

  ble4-service ::= "650a73d3-d7fd-4d08-b734-d11e25b0856d"

  ble5-service ::= "e5c245a3-1b7e-44cf-bc37-7040b719fe46"

  ble6-service ::= "eede145e-b6a6-4d61-8156-ed10d5b75903"

  espnow-channel ::= 1
  espnow-password ::= "pmk-esp32-123456"

  i2c-scl-pin ::= 32
  i2c-sda-pin ::= 33

  hc-sr04-trigger-pin ::= 18
  hc-sr04-echo-pin ::= 19

  ds18b20-pin ::= 15

  open-drain-test-pin ::= 18
  open-drain-level-pin ::= 19
  open-drain-measure-pin ::= 34

  gpio-pin-restricted ::= 7

  unconnected-pin1 ::= 2
  unconnected-pin2 ::= 4
  unconnected-pin3 ::= 16

  connected-pin1 ::= 22
  connected-pin2 ::= 23

  pulse-counter1-in2 ::= 33
  pulse-counter1-out2 ::= 26

  pulse-counter-channel-count ::= 8

  touch-pin1 ::= 2  // One of the unconnected pins.
  touch-pin2 ::= 4  // The other unconnected pin.

/**
A configuration for the ESP32-S3.

On board 1 connect as follows:
- IO10 - IO12 with 330Ohm
- IO12 - IO09 with 330Ohm
- IO09 - IO13 with 330Ohm
- IO13 - IO01 without any resistor
- IO01 - GND with 1MOhm (or similar high number).
- IO19 - IO21 with 330Ohm

Pins 6, 7, 8 must stay unconnected. 6 and 7 are used for touch tests.

On board2:
- IO01 -> bme280 SCL (yello)
- IO02 -> bme280 SDA (blue)
- IO13 -> HC-SR04 Echo. Ideally through a voltage divider or an LED.
- IO14 -> HC-SR04 Trig
- IO42 -> DS18B20 Data

Pins 19, 20, and 21 must stay unconnected.
*/
class Esp32s3 extends VariantBase implements Variant:
  adc1-pin ::= 9
  adc2-pin ::= 12
  adc-control-pin ::= 13
  adc-v33-pin ::= 10

  ble1-service ::= "94a11d6a-fa23-4a09-aa6f-2ca0b7cdbb70"
  ble1-service2 ::= "a479c6fc-e650-484b-a4e6-1c5bc4e02f25"

  ble2-service ::= "509070b2-011a-4568-8753-24a2f00ea25c"

  ble3-first-service ::= "f88e954e-1cb6-4e79-ab19-ed2b20015044"

  ble4-service ::= "9a657aaf-5b98-4e5b-bc21-872b09e6a243"

  ble5-service ::= "ef738562-e999-482d-88a1-16ea26fa18d3"

  ble6-service ::= "eed6e6d2-6f4f-46e4-9ed2-116515189eba"

  espnow-channel ::= 5
  espnow-password ::= "pmk-esp32s3-1234"

  i2c-scl-pin ::= 1
  i2c-sda-pin ::= 2

  hc-sr04-trigger-pin ::= 14
  hc-sr04-echo-pin ::= 13

  ds18b20-pin ::= 42

  // Use the same pins as the adc test.
  open-drain-test-pin ::= 13
  open-drain-level-pin ::= 9
  open-drain-measure-pin ::= 1

  gpio-pin-restricted ::= 33

  unconnected-pin1 ::= 6
  unconnected-pin2 ::= 7
  unconnected-pin3 ::= 8

  connected-pin1 ::= 4
  connected-pin2 ::= 5

  pulse-counter1-in2 ::= 19
  pulse-counter1-out2 ::= 21

  pulse-counter-channel-count ::= 4

  touch-pin1 ::= 6
  touch-pin2 ::= 7
