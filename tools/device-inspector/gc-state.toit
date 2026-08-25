// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

CHECKPOINTS ::= {
  "mutator-armed": {
    "id": 1,
    "phase": "mutator",
    "heap-structure": "stable",
    "object-graph": "stable",
    "mark-bits": "not-applicable",
    "normal-heap-census-safe": true,
    "context-kind": "none",
  },
  "scavenge-started": {
    "id": 2,
    "phase": "scavenge",
    "heap-structure": "transitional",
    "object-graph": "pre-forwarding",
    "mark-bits": "not-applicable",
    "normal-heap-census-safe": false,
    "context-kind": "two-space-heap",
  },
  "scavenge-after-forwarding": {
    "id": 3,
    "phase": "scavenge",
    "heap-structure": "transitional",
    "object-graph": "mixed-forwarded-and-original",
    "mark-bits": "not-applicable",
    "normal-heap-census-safe": false,
    "context-kind": "forwarded-object",
  },
  "scavenge-after-roots": {
    "id": 4,
    "phase": "scavenge",
    "heap-structure": "transitional",
    "object-graph": "roots-forwarded-transitive-scan-incomplete",
    "mark-bits": "not-applicable",
    "normal-heap-census-safe": false,
    "context-kind": "two-space-heap",
  },
  "scavenge-complete": {
    "id": 5,
    "phase": "scavenge",
    "heap-structure": "transitional",
    "object-graph": "forwarding-complete-before-space-swap",
    "mark-bits": "not-applicable",
    "normal-heap-census-safe": false,
    "context-kind": "two-space-heap",
  },
  "mark-after-roots": {
    "id": 6,
    "phase": "marking",
    "heap-structure": "stable-boundaries",
    "object-graph": "marking-incomplete",
    "mark-bits": "in-progress",
    "normal-heap-census-safe": false,
    "context-kind": "two-space-heap",
  },
  "mark-complete": {
    "id": 7,
    "phase": "marking",
    "heap-structure": "stable-boundaries",
    "object-graph": "marking-complete",
    "mark-bits": "complete",
    "normal-heap-census-safe": false,
    "context-kind": "two-space-heap",
  },
  "sweep-started": {
    "id": 8,
    "phase": "sweeping",
    "heap-structure": "stable-boundaries",
    "object-graph": "marked-dead-objects-not-reclaimed",
    "mark-bits": "complete",
    "normal-heap-census-safe": false,
    "context-kind": "two-space-heap",
  },
  "compaction-started": {
    "id": 9,
    "phase": "compacting",
    "heap-structure": "stable-boundaries",
    "object-graph": "destinations-computed-pointers-not-fixed",
    "mark-bits": "complete",
    "normal-heap-census-safe": false,
    "context-kind": "two-space-heap",
  },
  "gc-complete": {
    "id": 10,
    "phase": "mutator",
    "heap-structure": "stable",
    "object-graph": "stable",
    "mark-bits": "cleared",
    "normal-heap-census-safe": true,
    "context-kind": "two-space-heap",
  },
}

/** Describes the runtime phase supported by the target's stop evidence. */
describe observation/Map -> Map:
  checkpoint/Map? := observation.get "runtime-checkpoint"
  semantic-coherence := observation.get "semantic-coherence" --if-absent=: false
  capture-mode := observation.get "capture-mode" --if-absent=: "unknown"
  if not checkpoint:
    stable := semantic-coherence == true
    return {
      "capture-mode": capture-mode,
      "semantic-coherence": semantic-coherence,
      "checkpoint-known": false,
      "phase": stable ? "mutator" : "unknown",
      "heap-structure": stable ? "stable" : "unknown",
      "object-graph": stable ? "stable" : "unknown",
      "mark-bits": "unknown",
      "normal-heap-census-safe": stable,
      "diagnostics": stable
          ? []
          : [{"code": "RUNTIME_PHASE_NOT_AVAILABLE"}],
    }

  name := checkpoint.get "name"
  spec/Map? := name is string ? CHECKPOINTS.get name : null
  if not spec:
    return {
      "capture-mode": capture-mode,
      "semantic-coherence": semantic-coherence,
      "checkpoint": checkpoint,
      "checkpoint-known": false,
      "phase": "unknown",
      "heap-structure": "unknown",
      "object-graph": "unknown",
      "mark-bits": "unknown",
      "normal-heap-census-safe": false,
      "diagnostics": [{"code": "UNKNOWN_RUNTIME_CHECKPOINT"}],
    }

  result := spec.copy
  result["capture-mode"] = capture-mode
  result["semantic-coherence"] = semantic-coherence
  result["checkpoint"] = checkpoint
  result["checkpoint-known"] = true
  result["diagnostics"] = []
  checkpoint-id := checkpoint.get "id"
  if checkpoint-id is int and checkpoint-id != spec["id"]:
    result["checkpoint-known"] = false
    result["normal-heap-census-safe"] = false
    result["diagnostics"] = [{"code": "RUNTIME_CHECKPOINT_ID_MISMATCH"}]
  return result

/** Describes how one heap space participates in the current collector phase. */
space-view state/Map kind/string -> Map:
  phase := state["phase"]
  checkpoint/Map? := state.get "checkpoint"
  boundary := checkpoint ? checkpoint.get "name" : null
  result := {
    "phase": phase,
    "boundary": boundary,
    "space-kind": kind,
    "role": kind,
    "normal-model-safe": state["normal-heap-census-safe"],
  }
  if phase == "scavenge":
    if kind == "new-space":
      result["role"] = "from-space"
      result["object-state"] = boundary == "scavenge-complete"
          ? "forwarded-live-or-dead-unforwarded"
          : "forwarding-in-progress"
      result["missing-view"] = "temporary-to-space"
    else:
      result["role"] = "old-space-with-possible-promotions"
  else if phase == "marking":
    result["object-state"] = state["mark-bits"] == "complete"
        ? "live-or-dead-from-mark-bits"
        : "marking-in-progress"
  else if phase == "sweeping":
    result["object-state"] = "live-or-not-yet-reclaimed-dead"
  else if phase == "compacting":
    result["object-state"] = "pre-compaction-location"
  else:
    result["object-state"] = state["heap-structure"] == "stable"
        ? "normal"
        : "unknown"
  return result
