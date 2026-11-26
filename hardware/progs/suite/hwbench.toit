// Copyright (C) 2026 Toit contributors.

// Wall-clock benchmarks on real hardware: each benchmark of the device
// suite RUNS times, printing every run and the minimum and median
// ("BENCH name min-us median-us runs..."), then the free heap.

import system
import .richards as richards
import .deltablue as deltablue
import .pystone as pystone
import .suite show json-bench map-set-bench string-bench gc-stress

RUNS ::= 7

bench name/string [block] -> none:
  times := []
  RUNS.repeat:
    start := Time.monotonic-us
    block.call
    times.add Time.monotonic-us - start
  sorted := times.sort
  print "BENCH $name min $sorted[0] median $sorted[RUNS / 2] runs $times"

memory name/string -> none:
  stats := system.process-stats
  print "MEM $name system-free $stats[system.STATS-INDEX-SYSTEM-FREE-MEMORY] largest $stats[system.STATS-INDEX-SYSTEM-LARGEST-FREE]"

main:
  memory "boot"
  print "BENCH platform $(system.platform) $(system.architecture)"
  bench "richards": richards.run-richards
  bench "deltablue":
    deltablue.chain-test 50
    deltablue.projection-test 50
  bench "pystone": pystone.pystones --loops=2000
  bench "json": json-bench
  bench "map-set": map-set-bench
  bench "strings": string-bench
  bench "gc-stress": gc-stress
  // A tight loop (as in the spinner container) and a method-call loop.
  bench "loop-1M":
    sum := 0
    i := 0
    while i < 1_000_000:
      sum += i & 7
      i++
  bench "calls-200k":
    sum := 0
    200_000.repeat: sum = add sum it
  memory "end"
  print "BENCH done"

add a/int b/int -> int:
  return (a + b) & 0xffff
