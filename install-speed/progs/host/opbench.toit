// Copyright (C) 2026 Toit contributors.

// The benchmarks of hwbench and perfbench (without the RPC ones, which need
// a provider container), each run once, for dynamic opcode counts on a
// debug host build (-Xtrace, scripts/opcount.sh). "OPB name" starts the
// counts of a benchmark.

import encoding.json
import encoding.tison
import monitor
import ..suite.richards as richards
import ..suite.deltablue as deltablue
import ..suite.pystone as pystone
import ..suite.suite show json-bench map-set-bench string-bench gc-stress

bench name/string [block] -> none:
  print "OPB $name"
  block.call
  print "OPB -"

JSON-DATA ::= {
  "name": "device",
  "values": List 40: it * 3,
  "nested": { "a": [1, 2, {"b": "c"}], "d": 3.25, "e": null, "f": true },
}

main:
  bench "richards": richards.run-richards
  bench "deltablue":
    deltablue.chain-test 50
    deltablue.projection-test 50
  bench "pystone": pystone.pystones --loops=2000
  bench "json": json-bench
  bench "map-set": map-set-bench
  bench "strings": string-bench
  bench "gc-stress": gc-stress
  bench "loop-1M":
    sum := 0
    i := 0
    while i < 1_000_000:
      sum += i & 7
      i++
  bench "calls-200k":
    sum := 0
    200_000.repeat: sum = add sum it
  bench "yield-2k":
    2000.repeat: yield
  bench "tasks-1k":
    to := monitor.Channel 1
    back := monitor.Channel 1
    task::
      1000.repeat: back.send to.receive
    1000.repeat:
      to.send it
      back.receive
  bench "tison-2k":
    2000.repeat:
      tison.decode (tison.encode [it, 17])
  encoded := json.encode JSON-DATA
  bench "json-encode-30":
    30.repeat: json.encode JSON-DATA
  bench "json-decode-30":
    30.repeat: json.decode encoded
  bench "map-int-1k":
    map := {:}
    1000.repeat: map[it] = it * 2
    500.repeat: map.remove it
  bench "set-str-1k":
    set := {}
    strings := List 300: "s$it"
    1000.repeat: set.add strings[it % 300]
  bench "interp-1k":
    1000.repeat: "s$(it % 300)"

add a/int b/int -> int:
  return (a + b) & 0xffff
