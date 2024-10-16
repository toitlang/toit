# Raspberry Pi tests

This directory contains tests that should be run on a Raspberry Pi or other
embedded systems.

The tests are not run automatically, and might require a specific hardware setup.
Ideally they should eventually run automatically, but for now they should still
be useful for making sure that all of the functionality has been run at least
once. It should make refactoring easier too.

## Setup

Set the environment variables PIN1, ... appropriately and connect as follows. For
SPI use the first SPI interface:
- MOSI to PIN1 via a 300 Ohm resistor.
- PIN1 to PIN2 via a 10k resistor.
- SCLK to PIN2 via a 330 Ohm resistor.
- CS0 to PIN3.

### Sample configurations

Raspberry Pi v2 (https://www.raspberrypi.com/documentation/computers/images/GPIO-Pinout-Diagram-2.png):
- PIN1: GPIO24
- PIN2: GPIO23
- PIN3: GPIO25
