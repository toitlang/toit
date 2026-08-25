// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import io show LITTLE-ENDIAN

import ..compact-allocator as allocator
import ..description as description
import ..memory-accounting as accounting
import ..target as target

class TestRegion implements target.MemoryRegion:
  id/string := "ram"
  name/string := "RAM"
  address/int := 0x1000
  size/int := 0x4000
  kind/string := "ram"
  permissions/string := "rw"

  end-address -> int:
    return address + size

class TestTarget implements target.Target:
  id/string := "allocator-fixture"
  regions/List := [TestRegion]
  bytes_/ByteArray := ByteArray 0x4000

  read address/int length/int -> ByteArray:
    if not allows address length: throw "ADDRESS_NOT_CAPTURED"
    offset := address - 0x1000
    return bytes_[offset..offset + length]

  allows address/int length/int -> bool:
    return length > 0 and address >= 0x1000 and address + length <= 0x5000

  put address/int value/int -> none:
    LITTLE-ENDIAN.put-uint32 bytes_ (address - 0x1000) value

main:
  memory := TestTarget
  // registered_heaps -> descriptor -> one compact heap.
  memory.put 0x1000 0x1100
  memory.put 0x1100 0x1200
  memory.put 0x1104 0x5000
  memory.put 0x1108 0x1200
  memory.put 0x110c 0
  // Heap metadata: three pages at 0x2000, with two allocated and one free.
  memory.put 0x1200 0x1300
  memory.put 0x1208 0
  memory.put 0x120c 3
  memory.put 0x1210 0x2000
  memory.put 0x1214 0x5000
  memory.put 0x1218 1
  memory.put 0x121c 0xffff_ffa0  // CUSTOM_TAG_BASE + TOIT_HEAP_MALLOC_TAG.
  memory.put 0x1220 3
  memory.put 0x1224 0
  memory.put 0x1228 0
  memory.put 0x122c 0

  decoded := allocator.decode memory layout
  expect-equals "complete" decoded["state"]
  expect-equals 1 decoded["allocations"].size
  allocation/Map := decoded["allocations"][0]
  expect-equals "0x2000" allocation["address"]
  expect-equals 8_192 allocation["size"]
  expect-equals "toit-processes" allocation["allocator-tag"]["name"]
  expect-equals 8_192 decoded["summary"]["allocated-payload-bytes"]
  expect-equals 4_096 decoded["summary"]["free-bytes"]

  accounted := accounting.build memory {"process-groups": []} null layout
  expect-equals "complete" accounted["coverage"]["allocator-blocks"]
  expect-equals "partial" accounted["coverage"]["root-set"]
  expect-equals 8_192 accounted["summary"]["modeled-bytes"]
  expect-equals "unexplained" accounted["allocations"][0]["state"]
  expect-equals 8_192 accounted["allocation-tag-catalog"][4]["bytes"]
  expect-equals 1 accounted["allocation-tag-catalog"][4]["allocation-count"]
  free-tags := accounted["allocation-tag-catalog"].filter: it["id"] == 6
  expect-equals 1 free-tags.size
  expect-equals 4_096 free-tags[0]["bytes"]

  described := accounting.build
      memory
      {"process-groups": []}
      null
      layout
      {"native-ownership": description.native-ownership-v1}
  expect-equals
      "envelope-description"
      described["native-ownership"]["source"]
  no-native-decoders := accounting.build
      memory
      {"process-groups": []}
      null
      layout
      {"native-ownership": {
        "format": "toit-native-ownership",
        "format-version": 1,
        "decoders": [],
      }}
  expect-equals "not-enumerated" no-native-decoders["gc-metadata"]["state"]
  expect-equals
      "NATIVE_OWNERSHIP_DECODER_NOT_DECLARED"
      no-native-decoders["gc-metadata"]["reason"]
  unsupported-decoder := accounting.build
      memory
      {"process-groups": []}
      null
      layout
      {"native-ownership": {
        "format": "toit-native-ownership",
        "format-version": 1,
        "decoders": [{"id": "future-native-subsystem", "version": 1}],
      }}
  unsupported/List :=
      unsupported-decoder["native-ownership"]["unsupported-decoders"]
  expect-equals 1 unsupported.size
  expect-equals "future-native-subsystem" unsupported[0]["id"]
  expect-equals 1 unsupported[0]["version"]
  expect
      unsupported-decoder["diagnostics"].any:
        it["code"] == "NATIVE_OWNERSHIP_DECODER_NOT_SUPPORTED"

layout ::= {
  "format": "toit-runtime-layout",
  "format-version": 1,
  "pointer-size": 4,
  "byte-order": "little",
  "symbols": {
    "registered_heaps": {
      "present": true,
      "address": "0x1000",
    },
  },
  "types": {
    "heap_t": type 16 [
      field "start" 0,
      field "end" 4,
      field "heap" 8,
      field "next.sle_next" 12,
    ],
    "struct multi_heap_info": type 48 [
      field "end_of_heap_structure" 0,
      field "arenas" 4,
      field "number_of_pages" 12,
      field "page_base" 16,
      field "highest_address" 20,
      field "pages" 24,
    ],
    "arena_t": type 8 [field "previous" 0, field "next" 4],
    "header_t": type 8 [field "size_" 0, field "tag" 4],
    "Page": type 8 [field "status" 0, field "tag" 4],
  },
}

type size/int fields/List -> Map:
  return {"size": size, "fields": fields}

field name/string offset/int -> Map:
  return {"name": name, "offset": offset, "size": 4}
