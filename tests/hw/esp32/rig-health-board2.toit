// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio

import .rig-health-shared
import .test

main:
  run-test:
    input := gpio.Pin BOARD2-IN --input --pull-down
    output := gpio.Pin BOARD2-OUT --output
    output.set 0

    [1, 0, 1, 0].do: | level |
      wait-for-rig-level input BOARD2-IN level "board2" "peer request"
      output.set level

    print "Rig peer link healthy: board2 pins in=$BOARD2-IN out=$BOARD2-OUT"
