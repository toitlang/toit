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

  # The test didn't work for the ESP32S3. No need to run it.
  rmt-deprecated-test.toit-esp32s3

  # I2S is flaky and broken.
  # https://github.com/espressif/esp-idf/issues/15275
  i2s-test.toit-esp32
  i2s-board1.toit-esp32-msb8-slave
  i2s-board1.toit-esp32-pcm16-outstereoleft
  i2s-board1.toit-esp32-pcm16-outstereoright
  i2s-board1.toit-esp32-pcm16-outmonoboth
  i2s-board1.toit-esp32-pcm32-outstereoleft
  i2s-board1.toit-esp32-pcm32-inmonoleft
  i2s-board1.toit-esp32-pcm32-mclk
  i2s-test.toit-esp32s3
  i2s-board1.toit-esp32s3-msb16-writer-fast-slave
  i2s-board1.toit-esp32s3-pcm16-outstereoleft
  i2s-board1.toit-esp32s3-pcm16-outstereoright
  i2s-board1.toit-esp32s3-pcm16-outmonoboth
  i2s-board1.toit-esp32s3-pcm32-outstereoleft
  i2s-board1.toit-esp32s3-pcm32-mclk
  i2s-board1.toit-esp32-msb16
  i2s-board1.toit-esp32-philips32
  i2s-board1.toit-esp32-msb32
  i2s-board1.toit-esp32-pcm32
  i2s-board1.toit-esp32-pcm16-outmonoright
  i2s-board1.toit-esp32s3-msb16
  i2s-board1.toit-esp32s3-pcm16-outmonoleft
  i2s-board1.toit-esp32-pcm16
  i2s-board1.toit-esp32-pcm8
  i2s-board1.toit-esp32-pcm16-inmonoleft
  i2s-board1.toit-esp32-pcm16-inmonoright
  i2s-board1.toit-esp32-pcm16-outmonoleft
  i2s-board1.toit-esp32-philips16-slave
  i2s-board1.toit-esp32-philips16-writer
  i2s-board1.toit-esp32-philips16-writer-slave
  i2s-board1.toit-esp32-philips16-fast-slave
  i2s-board1.toit-esp32-philips24
  i2s-board1.toit-esp32-philips24-slave
  i2s-board1.toit-esp32-msb16-writer-fast-slave
  # Broken on the esp32s3 (same esp-idf I2S issue). Consistently failing in the
  # nightly (6/6) and reproduced locally; the generic philips16 variant still
  # works and stays enabled.
  i2s-board1.toit-esp32s3-pcm8
  i2s-board1.toit-esp32s3-msb8-slave
  # Flaky on the esp32s3 (~1/6 nightlies); the esp32 variant is already skipped
  # above. Same esp-idf I2S issue (#15275). Mostly passes but unreliable, and the
  # failure did not reproduce locally (12/12), so we skip rather than chase it.
  i2s-board1.toit-esp32s3-pcm32-inmonoleft
)

set(TOIT_FAILING_TESTS
)
