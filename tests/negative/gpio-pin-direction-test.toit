// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio

main:
  // Explicit directions are accepted, including optional input for output pins.
  gpio.Pin 5 --input
  gpio.Pin 5 --output
  gpio.Pin 5 --output --input
  gpio.Pin 5 --output --no-input
  gpio.Pin 5 --input --pull-up --no-pull-down --open-drain --allow-restricted --value=0
  gpio.Pin 5 --output --input --pull-up --no-pull-down --open-drain --allow-restricted --value=1
  gpio.Pin.in 5
  gpio.Pin.out 5

  // Omitting the direction is deprecated, including calls with other options.
  gpio.Pin 5
  gpio.Pin 5 --pull-up --no-pull-down --open-drain --allow-restricted --value=0

  // The required direction must be true.
  gpio.Pin 5 --no-input
  gpio.Pin 5 --no-output
  gpio.Pin 5 --input --no-output
  gpio.Pin 5 --no-input --no-output
