// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio

import .rig-health-shared
import .test

main:
  run-test:
    input := gpio.Pin BOARD1-IN --input --pull-down
    output := gpio.Pin BOARD1-OUT --output
    output.set 0
    wait-for-rig-level input BOARD1-IN 0 "board1" "initial peer low"

    [1, 0, 1, 0].do: | level |
      output.set level
      wait-for-rig-level input BOARD1-IN level "board1" "peer echo"

    print "Rig peer link healthy: board1 pins in=$BOARD1-IN out=$BOARD1-OUT"
