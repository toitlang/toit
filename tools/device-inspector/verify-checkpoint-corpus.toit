// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.json
import fs

import .api as api
import .format as format
import .gc-state as gc-state

main args/List:
  if args.size != 1: throw "EXPECTED_CORPUS_DIRECTORY"
  corpus := args[0]
  results := []
  gc-state.CHECKPOINTS.do: | name/string spec/Map |
    path := fs.join corpus name "device.toitdump"
    capture := format.load path
    state := gc-state.describe capture.observation
    if not state["checkpoint-known"]: throw "CORPUS_CHECKPOINT_NOT_RECOGNIZED"
    if state["checkpoint"]["name"] != name: throw "CORPUS_CHECKPOINT_MISMATCH"
    if state["checkpoint"]["id"] != spec["id"]: throw "CORPUS_CHECKPOINT_MISMATCH"
    runtime := api.runtime-detail capture
    runtime-state/Map := runtime["runtime-state"]
    if runtime-state["phase"] != spec["phase"]: throw "CORPUS_PHASE_MISMATCH"
    groups/List := runtime["process-groups"]
    if groups.is-empty: throw "CORPUS_RUNTIME_NOT_DISCOVERED"
    liveness := collect-liveness runtime
    expected-states := expected-liveness-states name
    if expected-states and not contains-any-state liveness expected-states:
      throw "CORPUS_GC_LIVENESS_NOT_DECODED"
    results.add {
      "name": name,
      "phase": state["phase"],
      "heap-structure": state["heap-structure"],
      "normal-heap-census-safe": state["normal-heap-census-safe"],
      "process-group-count": groups.size,
      "diagnostic-count": runtime["diagnostics"].size,
      "gc-liveness": liveness.values,
    }
  print (json.stringify {
    "event": "device-inspector-checkpoint-corpus-verified",
    "checkpoint-count": results.size,
    "items": results,
  })

collect-liveness runtime/Map -> Map:
  counters := {:}
  groups/List := runtime.get "process-groups" --if-absent=: []
  groups.do: | group/Map |
    processes/List := group.get "processes" --if-absent=: []
    processes.do: | process/Map |
      heap/Map? := process.get "object-heap"
      if not heap: continue.do
      ["old-space", "new-space"].do: | space-name/string |
        space/Map? := heap.get space-name
        if not space: continue.do
        census/Map? := space.get "census"
        if not census: continue.do
        entries/List := census.get "by-gc-liveness" --if-absent=: []
        entries.do: | entry/Map |
          state/string := entry["state"]
          counter/Map? := counters.get state
          if not counter:
            counter = {"state": state, "count": 0, "bytes": 0}
            counters[state] = counter
          counter["count"] += entry["count"]
          counter["bytes"] += entry["bytes"]
  return counters

expected-liveness-states checkpoint/string -> List?:
  if checkpoint == "scavenge-after-forwarding":
    return ["live-forwarded"]
  if checkpoint == "scavenge-complete":
    return ["live-forwarded", "dead-unforwarded"]
  if checkpoint == "mark-after-roots":
    return ["reached-so-far", "not-yet-reached"]
  if checkpoint == "mark-complete" or
      checkpoint == "sweep-started" or
      checkpoint == "compaction-started":
    return ["live", "dead"]
  return null

contains-any-state counters/Map expected/List -> bool:
  expected.do: | state/string |
    if counters.contains state: return true
  return false
