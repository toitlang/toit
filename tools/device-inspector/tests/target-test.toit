// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import io show LITTLE-ENDIAN

import ..inspector as inspector
import ..runtime as runtime
import ..target as target
import ..toit-model as toit-model

class TestRegion implements target.MemoryRegion:
  id/string
  name/string
  address/int
  size/int
  kind/string
  permissions/string

  constructor .id .name .address .size .kind .permissions:

  end-address -> int:
    return address + size

class IncrementalTarget implements target.Target:
  id/string := "incremental-test"
  regions/List
  bytes_/ByteArray
  reads/int := 0

  constructor .bytes_:
    regions = [TestRegion "memory" "Incremental memory" 0x1000 bytes_.size "ram" "rw"]

  read address/int length/int -> ByteArray:
    if not allows address length: throw "TEST_READ_OUTSIDE_MEMORY"
    reads++
    offset := address - 0x1000
    return bytes_[offset..offset + length]

  allows address/int length/int -> bool:
    return length > 0 and address >= 0x1000 and
        address + length <= 0x1000 + bytes_.size

main:
  bytes := ByteArray (runtime.SEARCH-READ-CHUNK + 8)
  LITTLE-ENDIAN.put-uint32 bytes 0 0x1005
  boundary := runtime.SEARCH-READ-CHUNK - 1
  bytes[boundary] = 0xaa
  bytes[boundary + 1] = 0xbb
  bytes[boundary + 2] = 0xcc
  target-instance := IncrementalTarget bytes
  interpretation := toit-model.Interpretation {
    "target": {"word-size": 4, "endianness": "little"},
    "completeness": {"semantic-coherence": true},
    "program-layouts": [],
  }
  decoder := inspector.Inspector target-instance interpretation

  word := decoder.word 0x1000
  expect-equals "heap-reference" word["candidate-kind"]
  expect-equals "ram" word["target-storage"]
  expect-equals "memory" word["target-region"]["id"]

  search := decoder.search #[0xaa, 0xbb, 0xcc] 100
  expect-equals 1 search["matches"].size
  expected-address := (0x1000 + boundary).to-string --radix=16
  expect-equals
      "0x$expected-address"
      search["matches"][0]["address"]
  expect target-instance.reads >= 3

  layout := {
    "methods": [{
      "header-bci": 0,
      "entry-bci": 4,
      "end-bci": 10,
      "name": "fixture",
      "kind": "method",
      "arity": 1,
      "max-height": 2,
      "path": "fixture.toit",
      "positions": [{"relative-bci": 0, "line": 7, "column": 3}],
    }],
  }
  symbolized := decoder.symbolize-layout-bci layout 6
  expect-equals "symbolized" symbolized["status"]
  expect-equals "fixture" symbolized["method"]["name"]
  expect-equals 7 symbolized["source"]["line"]
  expect-equals "unknown" (toit-model.symbolize-bci layout 20)["status"]
