# ESP32 tests

This directory contains tests for ESP functionality.

The tests are not run automatically, and might require a specific hardware setup.
Ideally they should eventually run automatically, but for now they should still
be useful for making sure that all of the functionality has been run at least
once. It should make refactoring easier too.

## Setup

The testing needs two boards and several resistors.

On board 1 connect as follows:
1. IO12 - IO14 with 330Ohm
2. IO14 - IO32 with 330Ohm
3. IO32 - IO25 with 330Ohm
4. IO2 and IO4 should be connected to a jumper wire but floating.
6. IO18 - IO34
7. IO18 (or IO34) - GND with 1MOhm (or similar high number).
5. IO18 - IO19 with 330Ohm
8. IO26 - IO33
9. IO15 - IO19 with 330Ohm

Connect board 1 to board 2 as follows:
1. GND - GND
2. IO22 - IO23
3. IO23 - IO22

## Running

As of 2023-05-30.
Run the tests individually. All test run on board 1, except for the
uart and wait_for tests. (See their respective files for more info.)

The adc test only works if no other program is using WiFi.
For Jaguar:
`jag container install -D jag.disabled -D jag.timeout=1m adc adc.toit`

Note that the touch test requires human interaction.

Known issues:
- dac.toit: the wave generator isn't working correctly. A patch
  https://github.com/espressif/esp-idf/pull/9430 to the ESP-IDF is needed.
- pulse_counter2.toit: the Pulse counter isn't correctly released. If, for
  any reason, pulse_counter1.toit fails it also requires a reset.
