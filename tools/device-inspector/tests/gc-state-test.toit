// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import io show LITTLE-ENDIAN

import ..gc-state as gc-state
import ..runtime as runtime
import ..target as target
import ..toit-model as toit-model

class TestRegion implements target.MemoryRegion:
  id/string := "gc-memory"
  name/string := "GC state fixture"
  address/int := 0x1000
  size/int
  kind/string := "ram"
  permissions/string := "rw"

  constructor .size:

  end-address -> int:
    return address + size

class GcTarget implements target.ObservedTarget:
  id/string := "gc-state-test"
  regions/List
  bytes_/ByteArray
  observation/Map

  constructor .observation:
    bytes_ = ByteArray 0x2000
    regions = [TestRegion bytes_.size]
    // The singleton's fixture mark-bitmap bias is at field offset zero.
    LITTLE-ENDIAN.put-uint32 bytes_ 0 0x2000
    // Object 0x2000 maps to bitmap address 0x2100 and bit zero.
    LITTLE-ENDIAN.put-uint32 bytes_ 0x1100 1

  read address/int length/int -> ByteArray:
    if not allows address length: throw "TEST_READ_OUTSIDE_MEMORY"
    offset := address - 0x1000
    return bytes_[offset..offset + length]

  allows address/int length/int -> bool:
    return length > 0 and address >= 0x1000 and
        address + length <= 0x1000 + bytes_.size

main:
  expected-phases := {
    "mutator-armed": "mutator",
    "scavenge-started": "scavenge",
    "scavenge-after-forwarding": "scavenge",
    "scavenge-after-roots": "scavenge",
    "scavenge-complete": "scavenge",
    "mark-after-roots": "marking",
    "mark-complete": "marking",
    "sweep-started": "sweeping",
    "compaction-started": "compacting",
    "gc-complete": "mutator",
  }
  expected-phases.do: | name/string phase/string |
    spec/Map := gc-state.CHECKPOINTS[name]
    state := gc-state.describe {
      "capture-mode": "runtime-checkpoint",
      "semantic-coherence": false,
      "runtime-checkpoint": {"name": name, "id": spec["id"]},
    }
    expect state["checkpoint-known"]
    expect-equals phase state["phase"]
    expect-equals
        (phase == "mutator")
        state["normal-heap-census-safe"]

  unknown := gc-state.describe {
    "capture-mode": "asynchronous",
    "semantic-coherence": false,
  }
  expect-equals "unknown" unknown["phase"]
  expect-not unknown["normal-heap-census-safe"]
  expect-equals "RUNTIME_PHASE_NOT_AVAILABLE" unknown["diagnostics"][0]["code"]

  observation := {
    "capture-mode": "runtime-checkpoint",
    "semantic-coherence": false,
    "runtime-checkpoint": {"name": "mark-complete", "id": 7},
  }
  memory := GcTarget observation
  interpretation := toit-model.Interpretation {
    "target": {"word-size": 4, "endianness": "little"},
    "completeness": {"semantic-coherence": false},
  }
  view := toit-model.View memory interpretation
  mark := runtime.read-gc-mark-bit view 0x2000 fixture-layout
  expect mark["marked"]
  expect-equals "0x2100" mark["bitmap-address"]
  liveness := runtime.gc-liveness-for-object
      view
      0x2000
      {"state": "normal-header", "type": "array"}
      fixture-layout
      (gc-state.describe observation)
      "old-space"
  expect-equals "live" liveness["state"]
  expect-equals "gc-mark-bit" liveness["evidence"]

  scavenge := gc-state.describe {
    "capture-mode": "runtime-checkpoint",
    "semantic-coherence": false,
    "runtime-checkpoint": {"name": "scavenge-complete", "id": 5},
  }
  forwarded := runtime.gc-liveness-for-object
      view
      0x2000
      {"state": "forwarded", "type": "array"}
      fixture-layout
      scavenge
      "new-space"
  dead := runtime.gc-liveness-for-object
      view
      0x2000
      {"state": "normal-header", "type": "array"}
      fixture-layout
      scavenge
      "new-space"
  expect-equals "live-forwarded" forwarded["state"]
  expect-equals "dead-unforwarded" dead["state"]
  space := gc-state.space-view scavenge "new-space"
  expect-equals "from-space" space["role"]
  expect-equals "temporary-to-space" space["missing-view"]

fixture-layout ::= {
  "format": "toit-runtime-layout",
  "format-version": 1,
  "pointer-size": 4,
  "byte-order": "little",
  "types": {
    "toit::GcMetadata": {
      "fields": [{"name": "mark_bits_bias_", "offset": 0}],
    },
  },
  "symbols": {
    "toit::GcMetadata::singleton_": {
      "present": true,
      "address": "0x1000",
    },
  },
  "constants": {},
}
