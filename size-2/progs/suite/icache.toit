// Copyright (C) 2026 Toit contributors.

// Workload of the instruction-cache estimate (scripts/icache-sim.sh): runs
// the benchmarks ROUNDS times (the difference between ROUNDS=2 and
// ROUNDS=1 is one run of each, without the boot).

import .richards as richards
import .deltablue as deltablue
import .pystone as pystone
import .rounds

main:
  ROUNDS.repeat:
    richards.run-richards
    deltablue.chain-test 50
    deltablue.projection-test 50
    pystone.pystones --loops=2000
  print "ICACHE done $ROUNDS"
