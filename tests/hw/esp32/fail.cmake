# Copyright (C) 2025 Toitware ApS.
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; version
# 2.1 only.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# The license can be found in the file `LICENSE` in the top level
# directory of this repository.


set(TOIT_SKIP_TESTS
  # The S3 doesn't have a DAC.
  dac-test.toit-esp32s3
  # We are missing a DHT11.
  dht11-board1.toit-esp32s3

  # I2S is flaky.
  # https://github.com/espressif/esp-idf/issues/15275
  i2s-test.toit-esp32
  i2s-board1.toit-esp32-msb8-slave
  i2s-board1.toit-esp32-pcm16-outstereoleft
  i2s-board1.toit-esp32-pcm16-outstereoright
  i2s-board1.toit-esp32-pcm16-outmonoboth
  i2s-board1.toit-esp32-pcm32-outstereoleft
  i2s-board1.toit-esp32-pcm32-inmonoleft
  i2s-test.toit-esp32s3
  i2s-board1.toit-esp32s3-msb16-writer-fast-slave
  i2s-board1.toit-esp32s3-pcm16-outstereoleft
  i2s-board1.toit-esp32s3-pcm16-outstereoright
  i2s-board1.toit-esp32s3-pcm16-outmonoboth
  i2s-board1.toit-esp32s3-pcm32-outstereoleft
)

set(TOIT_FAILING_TESTS
  # Idle level 1 doesn't seem to work.
  rmt-drain-pullup-test.toit-esp32s3
  # Probably just an issue with the number of RMT channels.
  rmt-test.toit-esp32s3
  # I2S is flaky and broken...
  # https://github.com/espressif/esp-idf/issues/15275
  i2s-board1.toit-esp32-msb16
  i2s-board1.toit-esp32-philips32
  i2s-board1.toit-esp32-msb32
  i2s-board1.toit-esp32-pcm32
)
