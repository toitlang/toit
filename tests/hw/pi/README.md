# Raspberry Pi tests

This directory contains tests that should be run on a Raspberry Pi or other
embedded systems.

The tests are not run automatically, and might require a specific hardware setup.
Ideally they should eventually run automatically, but for now they should still
be useful for making sure that all of the functionality has been run at least
once. It should make refactoring easier too.

## Setup

Set the environment variables SPI_MEASURE_MOSI, ... appropriately and connect as follows. For
SPI use the first SPI interface:
- MOSI to SPI_MEASURE_MOSI.
- SCLK to SPI_MEASURE_SCLK.
- CS0 to SPI_MEASURE_CS.

- GPIO_TEST to GPIO_LEVEL with a 330 Ohm (or any other 220-500) resistor.
- GPIO_TEST to GPIO_MEASURE.
- GPIO_TEST to GND with 1M Ohm resistor (or something similarly high).

### Sample configurations

Raspberry Pi v2 (https://www.raspberrypi.com/documentation/computers/images/GPIO-Pinout-Diagram-2.png):
- SPI_MEASURE_MOSI: GPIO24
- SPI_MEASURE_SCLK: GPIO23
- SPI_MEASURE_CS0: GPIO25
- GPIO_LEVEL: GPIO17
- GPIO_MEASURE: GPIO27
- GPIO_TEST: GPIO22
