# Raspberry Pi tests

This directory contains tests that should be run on a Raspberry Pi or other
embedded systems.

The tests are not run automatically, and might require a specific hardware setup.
Ideally they should eventually run automatically, but for now they should still
be useful for making sure that all of the functionality has been run at least
once. It should make refactoring easier too.

## Setup

Set the environment variables SPI_TEST_MOSI, ... appropriately and connect as follows. For
SPI use the first SPI interface:
- MOSI to SPI_TEST_MOSI.
- SCLK to SPI_TEST_SCLK.
- CS0 to SPI_TEST_CS.
- MISO to SPI_TEST_MISO.
- MOSI to MISO with a 5k Ohm resistor.

- GPIO_TEST to GPIO_LEVEL with a 330 Ohm (or any other 220-500) resistor.
- GPIO_TEST to GPIO_MEASURE, optionally with a 330 Ohm resistor (to avoid short circuits).
- GPIO_TEST to GND with 1M Ohm resistor (or something similarly high).
- GPIO_PIN1 is an alias for GPIO_TEST.
- GPIO_PIN2 is an alias for GPIO_MEASURE.

### Sample configurations

Raspberry Pi v2 (https://www.raspberrypi.com/documentation/computers/images/GPIO-Pinout-Diagram-2.png):
- SPI_TEST_MOSI: GPIO24
- SPI_TEST_SCLK: GPIO23
- SPI_TEST_CS: GPIO25
- SPI_TEST_MISO: GPIO16

- GPIO_LEVEL: GPIO17
- GPIO_MEASURE: GPIO27
- GPIO_TEST: GPIO22
- GPIO_PIN1: GPIO27
- GPIO_PIN2: GPIO22
