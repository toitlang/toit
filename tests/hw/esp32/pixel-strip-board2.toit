// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import rmt

import .pixel-strip-shared
import .test

main args:
  run-test:
    backend := args[0]
    input := rmt.In
        DATA-PIN
        --memory-blocks=RMT-MEMORY-BLOCKS
        --resolution=RESOLUTION
    ready := gpio.Pin READY-PIN --output

    try:
      3.repeat:
        input.start-reading --max-ns=50_000
        ready.set 1
        signals := input.wait-for-data
        validate-capture signals backend
        ready.set 0
        sleep --ms=1
    finally:
      ready.set 0
      ready.close
      input.close
