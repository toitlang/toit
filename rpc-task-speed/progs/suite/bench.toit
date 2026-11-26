// Copyright (C) 2026 Toit contributors.

// The suite's benchmarks alone (for comparing core builds, e.g. opt-levels).

import .richards as richards
import .deltablue as deltablue
import .pystone as pystone

time name/string [block] -> none:
  start := Time.monotonic-us
  block.call
  print "TIME $name $(Time.monotonic-us - start) us"

main:
  time "richards": richards.run-richards
  time "deltablue":
    deltablue.chain-test 50
    deltablue.projection-test 50
  time "pystone": pystone.pystones --loops=2000
  print "SUITE done"
