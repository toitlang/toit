// Copyright (C) 2025 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system

VARIANTS ::= {
  system.ARCHITECTURE-ESP32: Esp32,
  system.ARCHITECTURE-ESP32S3: Esp32s3,
}

/**
An ESP32 variant.

This class defines the pins for the ESP32 variants.
*/
abstract class Variant:
  static CURRENT/Variant ::= VARIANTS[system.architecture]

  /**
  The amount of pulse-counter channels this variant has.
  */
  abstract pulse-counter-channel-count -> int

  /** The number of input RMT channels. */
  abstract rmt-in-channel-count -> int
  /** The number of output RMT channels. */
  abstract rmt-out-channel-count -> int
  /** The total number of RMT channels that can be active at the same time. */
  abstract rmt-total-channel-count -> int

  /**
  A voltage divider consisting of three 330 Ohm resistors in series.
  The resistors must go from start->adc1->adc2->end.

  The adc1 pin must be an ADC pin of ADC1.
  The adc2 pin must be an ADC pin of ADC2 (if there is one).
  */
  abstract voltage-divider-start-pin -> int
  abstract voltage-divider-adc1-pin -> int
  abstract voltage-divider-adc2-pin -> int
  abstract voltage-divider-end-pin -> int

  /**
  A chain of 4 connected pins:
    GND - $chain2-to-gnd-pin - $chain2-pin2 - $chain2-pin3.

  GND and $chain2-to-gnd-pin are connected with a 1MOhm resistor.
  $chain2-to-gnd-pin is connected to $chain2-pin2 without any resistor.
  $chain2-pin2 is connected to $chain2-pin3 with a 330Ohm resistor.
  */
  abstract chain2-to-gnd-pin -> int
  abstract chain2-pin2 -> int
  abstract chain2-pin3 -> int

  /**
  Two pins that are connected with a 330 Ohm resistor.
  */
  abstract connected1-pin1 -> int
  abstract connected1-pin2 -> int

  /**
  Two more pins that are connected with a 330 Ohm resistor.
  */
  connected2-pin1 -> int: return voltage-divider-start-pin
  connected2-pin2 -> int: return voltage-divider-adc1-pin

  /**
  A pin that is restricted.
  */
  abstract restricted-pin -> int

  /**
  An unconnected pin.

  $unconnected-pin1 and $unconnected-pin2 are set to the touch pins by
    default, since these should not be connected to anything while the
    touch test isn't running.
  */
  unconnected-pin1 -> int: return touch-pin1
  unconnected-pin2 -> int: return touch-pin2
  abstract unconnected-pin3 -> int

  /**
  Touch pins.

  Connect a jumper wire to the touch pins. These should otherwise be
    unconnected.
  $touch-pin1 should be yellow.
  $touch-pin2 should be green.

  # Inheritance
  If the board does not have touch pins, then the $unconnected-pin1 and
    $unconnected-pin2 must be overridden, since these default to the touch pins.
  */
  abstract touch-pin1 -> int
  abstract touch-pin2 -> int

  /**
  Distinct service UUIDs for each ble test.
  */
  abstract ble1-service -> string
  abstract ble1-service2 -> string

  abstract ble2-service -> string

  abstract ble3-first-service -> string

  abstract ble4-service -> string

  abstract ble5-service -> string

  abstract ble6-service -> string

  abstract ble7-service -> string

  /**
  The ESP-NOW channel and password.

  Different for each variant.
  */
  abstract espnow-channel -> int
  abstract espnow-password -> string

  /**
  I2C pins.

  On board 2.
  Typically, scl is yellow and sda is blue.
  */
  abstract board2-i2c-scl-pin -> int
  abstract board2-i2c-sda-pin -> int

  /**
  HC-SR04 pins.

  Since the HC-SR04 is a 5V device, the echo pin should not be connected
    directly to the ESP32. Instead, it should be connected through a voltage
    divider or an LED (or through a level shifter).
  */
  abstract board2-hc-sr04-trigger-pin -> int
  abstract board2-hc-sr04-echo-pin -> int

  /*
  DS18B20 pins.
  */
  abstract board2-ds18b20-pin -> int

  /**
  DHT11 pins.
  */
  abstract board2-dht11-pin -> int

  /**
  Board connections.

  Pins that are connected between the two boards.
  Pin 1 and 2 are crossed, so that the same pin number can be
    used as RX/TX on both boards.

  Pin 3 goes to the same pin on both boards.
  Pin 4 goes to the same pin on both boards.
  Pin 5 goes to the same pin on both boards.
  Pin 6 goes to the same pin on both boards.

  Pin 5 and 6 must be connected with a 5K resistor.
  */
  abstract board-connection-pin1 -> int
  abstract board-connection-pin2 -> int
  abstract board-connection-pin3 -> int
  abstract board-connection-pin4 -> int
  abstract board-connection-pin5 -> int
  abstract board-connection-pin6 -> int

  /*
  ADC.

  The $adc-control-pin and $adc-v33-pin are connected through
    two resistors (each of the same value). At each connection
    point we have one of the adc pins. The $adc1-pin is closer to
    the 3.3V pin and the $adc2-pin is closer to the ground pin.
  */
  adc-control-pin -> int: return voltage-divider-start-pin
  adc1-pin -> int: return voltage-divider-adc1-pin
  adc2-pin -> int: return voltage-divider-adc2-pin
  adc-v33-pin -> int: return voltage-divider-end-pin

  /**
  Digital-analog conversions pins.

  Connect a DAC pin as $dac-out1-pin to $dac-in1-pin with a 330Ohm resistor.
  Connect a DAC pin as $dac-out2-pin to $dac-in2-pin with a 330Ohm resistor.
  */
  abstract dac-out1-pin -> int
  abstract dac-in1-pin -> int

  abstract dac-out2-pin -> int
  abstract dac-in2-pin -> int

  /*
  Open drain test pins.

  The $open-drain-test-pin is connected to the $open-drain-level-pin
    through a 330Ohm resistor.
  The $open-drain-test-pin and $open-drain-measure-pin are connected
    without any resistor.
  The $open-drain-test-pin or $open-drain-measure-pin is connected to GND
    through a 1MOhm resistor.
  */
  open-drain-measure-pin -> int: return chain2-to-gnd-pin
  open-drain-test-pin -> int: return chain2-pin2
  open-drain-level-pin -> int: return chain2-pin3

  /*
  GPIO pins.

  Connect $gpio-pin1 to $gpio-pin2 with a 330Ohm resistor.
  Set the $gpio-pin-restricted to a pin that is restricted.
  */
  gpio-pin1 -> int: return connected1-pin1
  gpio-pin2 -> int: return connected1-pin2
  gpio-pin-restricted -> int: return restricted-pin

  /**
  I2C pullup test pins.

  $i2c-pullup-test-pin is connected to $i2c-pullup-measure-pin without any
    resistor.
  $i2c-pullup-measure-pin is connected to GND through a 1MOhm resistor.
  Also uses $unconnected-pin1.
  */
  i2c-pullup-measure-pin -> int: return chain2-to-gnd-pin
  i2c-pullup-test-pin -> int: return chain2-pin2
  i2c-pullup-other-pin -> int: return unconnected-pin1

  /**
  Pulse counter pins.

  Connect $pulse-counter1-in1 to $pulse-counter1-out1 with a 330Ohm resistor.
  Connect $pulse-counter1-in2 to $pulse-counter1-out2 with a 330Ohm resistor.
  */
  pulse-counter1-in1 -> int: return connected1-pin1
  pulse-counter1-out1 -> int: return connected1-pin2

  pulse-counter1-in2 -> int: return connected2-pin1
  pulse-counter1-out2 -> int: return connected2-pin2

  /**
  PWM pins.

  Connect $pwm-in1 to $pwm-out1 with a 330Ohm resistor.
  Connect $pwm-in2 to $pwm-out2 with a 330Ohm resistor.
  */
  pwm-in1 -> int: return connected1-pin1
  pwm-out1 -> int: return connected1-pin2

  pwm-in2 -> int: return connected2-pin1
  pwm-out2 -> int: return connected2-pin2

  /**
  RMT pull-up test pins.

  Same as $open-drain-test-pin and $open-drain-level-pin.
  */
  rmt-drain-pullup-measure-pin -> int: return chain2-to-gnd-pin
  rmt-drain-pullup-test-pin -> int: return chain2-pin2
  rmt-drain-pullup-level-pin -> int: return chain2-pin3

  /**
  RMT many test pins.

  Connect $rmt-many-in1 to $rmt-many-out1 with a 330Ohm resistor.
  Connect $rmt-many-in2 to $rmt-many-out2 with a 330Ohm resistor.
  */
  rmt-many-in1 -> int: return connected1-pin1
  rmt-many-out1 -> int: return connected1-pin2

  rmt-many-in2 -> int: return connected2-pin1
  rmt-many-out2 -> int: return connected2-pin2

  /**
  RMT pins.

  Connect $rmt-pin1 to $rmt-pin2 with a 330Ohm resistor.
  Connect $rmt-pin2 to $rmt-pin3 with a 330Ohm resistor.
  */
  rmt-pin1 -> int: return voltage-divider-start-pin
  rmt-pin2 -> int: return voltage-divider-adc1-pin
  rmt-pin3 -> int: return voltage-divider-adc2-pin

  /**
  SPI keep-active pins.

  Connect $spi-keep-active-cs-pin to $spi-keep-active-in-cs-pin with a 330Ohm resistor.
  */
  spi-keep-active-cs-pin -> int: return connected1-pin1
  spi-keep-active-in-cs-pin -> int: return connected1-pin2

  /**
  Uart baud-rate pins.

  Connect $uart-baud-rate-in1 to $uart-baud-rate-out1 with a 330Ohm resistor.
  Connect $uart-baud-rate-in2 to $uart-baud-rate-out2 with a 330Ohm resistor.
  */
  uart-baud-rate-in1 -> int: return connected1-pin1
  uart-baud-rate-out1 -> int: return connected1-pin2

  uart-baud-rate-in2 -> int: return connected2-pin1
  uart-baud-rate-out2 -> int: return connected2-pin2

  /**
  Uart flush test pins.

  Connect $uart-flush-in1 to $uart-flush-out1 with a 330Ohm resistor.
  Connect $uart-flush-in2 to $uart-flush-out2 with a 330Ohm resistor.
  */
  uart-flush-in1 -> int: return connected1-pin1
  uart-flush-out1 -> int: return connected1-pin2

  uart-flush-in2 -> int: return connected2-pin1
  uart-flush-out2 -> int: return connected2-pin2


  /**
  Uart flush test pins.

  Connect $uart-error-in1 to $uart-error-out1 with a 330Ohm resistor.
  Connect $uart-error-in2 to $uart-error-out2 with a 330Ohm resistor.
  */
  uart-error-in1 -> int: return connected1-pin1
  uart-error-out1 -> int: return connected1-pin2

  uart-error-in2 -> int: return connected2-pin1
  uart-error-out2 -> int: return connected2-pin2

  /**
  Uart io-data pins.

  Connect $uart-io-data-in1 to $uart-io-data-out1 with a 330Ohm resistor.
  Connect $uart-io-data-in2 to $uart-io-data-out2 with a 330Ohm resistor.
  */
  uart-io-data-in1 -> int: return connected1-pin1
  uart-io-data-out1 -> int: return connected1-pin2

  uart-io-data-in2 -> int: return connected2-pin1
  uart-io-data-out2 -> int: return connected2-pin2

  /**
  Wait-for-close test pins.

  The $wait-for-close-pin should be connected to GND with a 1MOhm resistor.
  */
  wait-for-close-pin -> int: return chain2-to-gnd-pin

  /**
  I2S pins.

  Connect $i2s-data1 to $i2s-data2 with a 330Ohm resistor.
  Connect $i2s-clk1 to $i2s-clk2 with a 330Ohm resistor.
  Connect $i2s-ws1 to $i2s-ws2 with a 330Ohm resistor.
    By default the $i2s-ws2 is also connected to GND by a 1MOhm resistor.
    That shouldn't have any effect on the test.
  */
  i2s-data1 -> int: return connected1-pin1
  i2s-data2 -> int: return connected1-pin2

  i2s-clk1 -> int: return connected2-pin1
  i2s-clk2 -> int: return connected2-pin2

  i2s-ws1 -> int: return chain2-pin2
  i2s-ws2 -> int: return chain2-pin3

/*
A configuration for the ESP32.

On board 1 connect as follows:
- a voltage divider consisting of 4 pins each connected with a
  330Ohm resistor, continued to 2 more pins with a 5k and 330Ohm
  IO27 (start) - IO32 (ADC1_4) - IO26 (ADC2_9/DAC_2) - IO14 (end) - IO13 - IO36

  The connection between IO14 and IO13 must be a 5K resistor.
  IO36 is input only.

- IO25 (DAC1) - IO33 with 330Ohm

- IO13 (also connected with board2) - IO17 (also connected with board2) with 5KOhm.  xx

- The following pins in a row: GND - IO21 - IO19 - IO18
  * IO21 to GND with a 1MOhm resistor.
  * IO21 to IO19 without any resistor.
  * IO19 to IO18 with a 330Ohm resistor.

IO2, IO4, and IO16 must stay unconnected (or connected to the other board).
Pins IO4 and IO2 are used for touch tests.

On board2:
- IO19 -> HC-SR04 Echo. Ideally through a voltage divider or an LED.
- IO18 -> HC-SR04 Trig
- IO15 -> DHT11 Data
- IO14 -> DS18B20 Data
- IO32 -> bme280 SCL (yellow)
- IO33 -> bme280 SDA (blue)

IO2, IO4, and IO16 must stay unconnected.

Connect the two boards.
- GND (board1) - GND (board2)
- IO22 (board1) - IO23 (board2)
- IO23 (board1) - IO22 (board2)
- IO16 (board1) - IO16 (board2)
- IO27 (board1) - IO27 (board2)
- IO17 (board1) - IO17 (board2)
- IO13 (board1) - IO13 (board2)
*/
class Esp32 extends Variant:
  pulse-counter-channel-count ::= 8
  rmt-in-channel-count ::= 8
  rmt-out-channel-count ::= 8
  rmt-total-channel-count ::= 8

  voltage-divider-start-pin ::= 27
  voltage-divider-adc1-pin ::= 32
  voltage-divider-adc2-pin ::= 26
  voltage-divider-end-pin ::= 14

  chain2-to-gnd-pin ::= 21
  chain2-pin2 ::= 19
  chain2-pin3 ::= 18

  connected1-pin1 ::= 25
  connected1-pin2 ::= 33

  dac-out1-pin ::= 25
  dac-in1-pin ::= 33

  dac-out2-pin ::= 26
  dac-in2-pin ::= 32

  restricted-pin ::= 7

  touch-pin1 ::= 2
  touch-pin2 ::= 4
  unconnected-pin3 ::= 16

  ble1-service ::= "df451d2d-e899-4346-a8fd-bca9cbfebc0b"
  ble1-service2 ::= "94a11d6a-fa23-4a09-aa6f-2ca0b7cdbb70"

  ble2-service ::= "a1bcf0ba-7557-4968-91f8-6b0f187af2b5"

  ble3-first-service ::= "ffe21239-d8a2-4536-b751-0881a9f2e3de"

  ble4-service ::= "650a73d3-d7fd-4d08-b734-d11e25b0856d"

  ble5-service ::= "e5c245a3-1b7e-44cf-bc37-7040b719fe46"

  ble6-service ::= "eede145e-b6a6-4d61-8156-ed10d5b75903"

  ble7-service ::= "2c099659-d917-41a2-955d-18a4966b54c8"

  espnow-channel ::= 1
  espnow-password ::= "pmk-esp32-123456"

  board2-i2c-scl-pin ::= 32
  board2-i2c-sda-pin ::= 33

  board2-hc-sr04-trigger-pin ::= 18
  board2-hc-sr04-echo-pin ::= 19

  board2-ds18b20-pin ::= 14

  board2-dht11-pin ::= 15

  board-connection-pin1 ::= 22
  board-connection-pin2 ::= 23
  board-connection-pin3 ::= 16
  board-connection-pin4 ::= 27
  board-connection-pin5 ::= 17
  board-connection-pin6 ::= 13

/**
A configuration for the ESP32-S3.

On board 1 connect as follows:
- a voltage divider consisting of 4 pins each connected with a
  330Ohm resistor.
  IO13 (start) - IO09 (ADC1) - IO12 (ADC2) - IO10 (end)

- IO19 - IO21 with 330Ohm

- IO38 (also connected to board2) - IO47 (also connected to board2) with 5KOhm.

- The following pins in a row: GND - IO1 - IO2 - IO42
  * IO1 to GND with a 1MOhm resistor.
  * IO1 to IO2 without any resistor.
  * IO2 to IO42 with a 330Ohm resistor.

IO6, IO7, and IO8 must stay unconnected.
Pins IO6 and IO7 are used for touch tests.

On board2:
- IO01 -> bme280 SCL (yello)
- IO02 -> bme280 SDA (blue)
- IO13 -> HC-SR04 Echo. Ideally through a voltage divider or an LED.
- IO14 -> HC-SR04 Trig
- IO42 -> DS18B20 Data

IO6, IO7, and IO8 must stay unconnected.

Connect the two boards.
- GND (board1) - GND (board2)
- IO04 (board1) - IO05 (board2)
- IO05 (board1) - IO04 (board2)
- IO21 (board1) - IO21 (board2)
- IO17 (board1) - IO17 (board2)
- IO47 (board1) - IO47 (board2)
- IO38 (board1) - IO38 (board2)
*/
class Esp32s3 extends Variant:
  pulse-counter-channel-count ::= 4
  rmt-in-channel-count ::= 4
  rmt-out-channel-count ::= 4
  rmt-total-channel-count ::= 8

  voltage-divider-start-pin ::= 13
  voltage-divider-adc1-pin ::= 9
  voltage-divider-adc2-pin ::= 12
  voltage-divider-end-pin ::= 10

  dac-out1-pin -> int: return unconnected-pin1
  dac-in1-pin -> int: return unconnected-pin2

  dac-out2-pin -> int: return unconnected-pin1
  dac-in2-pin -> int: return unconnected-pin3

  chain2-to-gnd-pin ::= 1
  chain2-pin2 ::= 2
  chain2-pin3 ::= 42

  connected1-pin1 ::= 19
  connected1-pin2 ::= 21

  restricted-pin ::= 33

  touch-pin1 ::= 6
  touch-pin2 ::= 7
  unconnected-pin3 ::= 8

  ble1-service ::= "94a11d6a-fa23-4a09-aa6f-2ca0b7cdbb70"
  ble1-service2 ::= "a479c6fc-e650-484b-a4e6-1c5bc4e02f25"

  ble2-service ::= "509070b2-011a-4568-8753-24a2f00ea25c"

  ble3-first-service ::= "f88e954e-1cb6-4e79-ab19-ed2b20015044"

  ble4-service ::= "9a657aaf-5b98-4e5b-bc21-872b09e6a243"

  ble5-service ::= "ef738562-e999-482d-88a1-16ea26fa18d3"

  ble6-service ::= "eed6e6d2-6f4f-46e4-9ed2-116515189eba"

  ble7-service ::= "0c9b0be3-1612-447d-ba1e-ab7293a3c795"

  espnow-channel ::= 5
  espnow-password ::= "pmk-esp32s3-1234"

  board2-i2c-scl-pin ::= 1
  board2-i2c-sda-pin ::= 2

  board2-hc-sr04-trigger-pin ::= 14
  board2-hc-sr04-echo-pin ::= 13

  board2-ds18b20-pin ::= 42

  // We currently don't have any DHT11 sensor connected to this board.
  board2-dht11-pin -> int: return unconnected-pin1

  board-connection-pin1 ::= 4
  board-connection-pin2 ::= 5
  board-connection-pin3 ::= 21
  board-connection-pin4 ::= 17
  board-connection-pin5 ::= 47
  board-connection-pin6 ::= 38
