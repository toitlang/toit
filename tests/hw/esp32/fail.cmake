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
)

set(TOIT_FAILING_TESTS
  # The anti-glitching doesn't seem to work.
  pulse-counter-test.toit-esp32s3
  # Idle level 1 doesn't seem to work.
  rmt-drain-pullup-test.toit-esp32s3
  # Probably just an issue with the number of RMT channels.
  rmt-test.toit-esp32s3
)
