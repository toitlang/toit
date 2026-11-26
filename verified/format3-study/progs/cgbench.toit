// Copyright (C) 2026 Toit contributors.

// The compute benchmarks of opbench, one per run, for callgrind instruction
// counts: `cgbench NAME N` runs N iterations of benchmark NAME (N = 0 gives
// the fixed cost to subtract). Tasks, yield and RPC: taskbench.toit.

import ..suite.richards as richards
import ..suite.deltablue as deltablue
import ..suite.pystone as pystone
import ..suite.suite show json-bench map-set-bench string-bench gc-stress

main args:
  name := args[0]
  n := int.parse args[1]
  n.repeat:
    if name == "richards": richards.run-richards
    else if name == "deltablue":
      deltablue.chain-test 50
      deltablue.projection-test 50
    else if name == "pystone": pystone.pystones --loops=2000
    else if name == "json": json-bench
    else if name == "map-set": map-set-bench
    else if name == "strings": string-bench
    else if name == "gc-stress": gc-stress
    else if name == "calls":
      sum := 0
      200_000.repeat: sum = add sum it
    else: throw "unknown benchmark $name"

add a/int b/int -> int:
  return (a + b) & 0xffff
