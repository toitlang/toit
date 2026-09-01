# ESP32 I²C slave for EC618 long-transfer tests

This ESP-IDF application makes an ESP32 a deterministic I²C slave for
[`i2c-long-transfer-ec618.toit`](../i2c-long-transfer-ec618.toit). It checks
the exact length and contents of a 1,025-byte write, and supplies deterministic
data for 1,025-byte read and combined write-read tests.

Wire the boards as follows, with a shared ground:

| Signal | EC618 dev board | ESP32 |
| --- | --- | --- |
| SDA | PAD14 | GPIO18 |
| SCL | PAD13 | GPIO17 |
| Ground | GND | GND |

The application enables the ESP32's internal pull-ups. External 4.7 kΩ
pull-ups to 3.3 V are preferable when available.

From the repository root, using the ESP32's serial port for `PORT`:

```sh
. third_party/esp-idf/export.sh
idf.py -C tests/hw/ec618/esp-idf-i2c-slave set-target esp32
idf.py -C tests/hw/ec618/esp-idf-i2c-slave build
idf.py -C tests/hw/ec618/esp-idf-i2c-slave -p PORT flash monitor
```

The slave uses address `0x42`. Its ready message reports the address and GPIO
assignment.

The ESP-IDF v2 slave driver on the classic ESP32 can retain prefetched TX
bytes after a master stops reading. Reset the ESP32 fixture before each test
invocation (the EC618 stays live):

```sh
esptool --chip esp32 --port PORT --after hard-reset run
```

Do not reset the fixture through an I²C command: disappearing before the
master observes the final ACK/STOP turns fixture setup into a bus-recovery
test.
