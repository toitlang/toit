// Copyright (C) 2026 Toit contributors.

// The components of the RPC and json/map-set gaps (branch device/hw-perf):
// each benchmark RUNS times, "BENCH name min-us median-us runs...". With a
// TOIT_HW_PERF firmware every run is bracketed by Profiler.start (resets
// the counters) and Profiler.stop (prints them, "[hw-perf]" lines); on
// other firmware those calls fail and are ignored.

import encoding.json
import encoding.tison
import monitor
import system
import system.containers
import uuid

import .echo-service
import .suite show json-bench map-set-bench string-bench

RUNS ::= 7

bench name/string [block] -> none:
  times := []
  RUNS.repeat:
    perf := (catch: Profiler.start) == null
    if perf: print "[hw-perf] begin $name"
    start := Time.monotonic-us
    block.call
    times.add Time.monotonic-us - start
    if perf: Profiler.stop
  sorted := times.sort
  print "BENCH $name min $sorted[0] median $sorted[RUNS / 2] runs $times"

find-image name/string -> uuid.Uuid?:
  containers.images.do: | image/containers.ContainerImage |
    if image.name == name: return image.id
  return null

JSON-DATA ::= {
  "name": "device",
  "values": List 40: it * 3,
  "nested": { "a": [1, 2, {"b": "c"}], "d": 3.25, "e": null, "f": true },
}

main:
  print "BENCH platform $(system.platform) $(system.architecture)"
  provider := containers.start (find-image "provider")
  client := EchoServiceClient
  client.open --timeout=(Duration --s=10)
  bench "rpc-200":
    s := 0
    200.repeat: s = client.add s it
  payload := [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, "one", "two", "three", "four", "five"]
  bench "rpc-echo-50":
    50.repeat: client.echo payload
  client.close
  provider.stop

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
  bench "json": json-bench
  encoded := json.encode JSON-DATA
  bench "json-encode-30":
    30.repeat: json.encode JSON-DATA
  bench "json-decode-30":
    30.repeat: json.decode encoded
  bench "map-set": map-set-bench
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
  bench "strings": string-bench
  print "BENCH done"
