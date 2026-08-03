// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import rmt

import .pixel-strip-shared
import .test

main _:
  run-test:
    input := rmt.In
        DATA-PIN
        --memory-blocks=RMT-MEMORY-BLOCKS
        --resolution=RESOLUTION
    ready := gpio.Pin READY-PIN --output

    try:
      input.start-reading --max-ns=50_000
      ready.set 1
      signals := input.wait-for-data
      validate-capture signals
    finally:
      ready.set 0
      ready.close
      input.close
