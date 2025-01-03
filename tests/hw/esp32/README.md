# ESP32 tests

This directory contains tests for ESP functionality.

The tests are not run automatically, and might require a specific hardware setup.
Ideally they should eventually run automatically, but for now they should still
be useful for making sure that all of the functionality has been run at least
once. It should make refactoring easier too.

All tests should be run once after a reboot, and then again without a reboot.

## Setup

The testing needs two boards and several resistors.

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
- IO19 -> HC-SR04 Echo
- IO18 -> HC-SR04 Trig
- IO14 -> DHT11 Data
- IO15 -> DS18B20 Data
- IO32 -> bme280 SCL (yellow)
- IO33 -> bme280 SDA (blue)

IO16 must stay unconnected.

## Running

As of 2023-05-30.
Run the tests individually. All test run on board 1, except for the
ble, uart, ultrasound, wait-for tests, and pin-hold tests. (See their respective files for more info.)

The adc and espnow tests only work if no other program is using WiFi.
For Jaguar:
`jag container install -D jag.disabled -D jag.timeout=1m adc adc.toit`

Note that the touch test requires human interaction.
