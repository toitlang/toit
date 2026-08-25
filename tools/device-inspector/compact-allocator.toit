// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.

import .format as format
import .runtime as runtime
import .target as target

MAX-HEAPS ::= 64
MAX-ARENAS ::= 4_096
MAX-SMALL-ALLOCATIONS ::= 200_000
PAGE-SIZE ::= 4_096
PAGE-FREE ::= 0
PAGE-IN-USE ::= 1
PAGE-IN-USE-FOR-MALLOCS ::= 2
PAGE-CONTINUED ::= 3
CUSTOM-TAG-BASE ::= -100

REQUIRED-TYPES ::= [
  "heap_t",
  "struct multi_heap_info",
  "arena_t",
  "header_t",
  "Page",
]

/** Decodes ESP-IDF's compact allocator without executing target code. */
decode memory/target.Target layout/Map -> Map:
  if not (supported layout):
    return {
      "state": "unavailable",
      "allocations": [],
      "heaps": [],
      "diagnostics": [{
        "code": "COMPACT_ALLOCATOR_LAYOUT_UNAVAILABLE",
        "message": "Regenerate the runtime layout from the exact ELF to decode allocator blocks.",
      }],
    }

  allocations := []
  heaps := []
  diagnostics := []
  head-address := runtime.layout-symbol-address layout "registered_heaps"
  next := 0
  head-exception := catch: next = read-word memory head-address
  if head-exception:
    return {
      "state": "partial",
      "consistency": "unavailable",
      "allocations": [],
      "heaps": [],
      "summary": allocator-summary [] [],
      "diagnostics": [{
        "code": "ALLOCATOR_REGISTRY_NOT_CAPTURED",
        "address": format.hex-address head-address,
        "message": "$head-exception",
      }],
    }
  visited := {}
  heap-index := 0
  while next != 0 and heap-index < MAX-HEAPS:
    if visited.contains next:
      diagnostics.add (diagnostic "ALLOCATOR_HEAP_LIST_CYCLE" next)
      break
    visited.add next
    descriptor := next
    next-offset := runtime.layout-field-offset layout "heap_t" "next.sle_next"
    exception := catch:
      next = read-pointer-field memory layout "heap_t" descriptor "next.sle_next"
      heap := decode-heap memory layout descriptor heap-index allocations
      heaps.add heap
      heap["diagnostics"].do: diagnostics.add it
    if exception:
      diagnostics.add {
        "code": "ALLOCATOR_HEAP_DECODE_FAILED",
        "address": format.hex-address descriptor,
        "message": "$exception",
      }
      if memory.allows (descriptor + next-offset) 4:
        next = read-word memory (descriptor + next-offset)
      else:
        next = 0
    heap-index++
  if heap-index == MAX-HEAPS and next != 0:
    diagnostics.add (diagnostic "ALLOCATOR_HEAP_LIST_LIMIT" next)

  return {
    "state": diagnostics.is-empty ? "complete" : "partial",
    "consistency": "stopped-image-structural",
    "allocations": allocations,
    "heaps": heaps,
    "summary": allocator-summary heaps allocations,
    "diagnostics": diagnostics,
  }

supported layout/Map -> bool:
  types/Map := layout.get "types" --if-absent=: {:}
  REQUIRED-TYPES.do: | name/string |
    if not (types.contains name): return false
  symbols/Map := layout.get "symbols" --if-absent=: {:}
  symbol := symbols.get "registered_heaps"
  return symbol and (symbol.get "present" --if-absent=: false)

decode-heap
    memory/target.Target layout/Map descriptor/int heap-index/int allocations/List
    -> Map:
  start := read-pointer-field memory layout "heap_t" descriptor "start"
  end := read-pointer-field memory layout "heap_t" descriptor "end"
  heap := read-pointer-field memory layout "heap_t" descriptor "heap"
  if heap == 0:
    return {
      "index": heap-index,
      "descriptor": format.hex-address descriptor,
      "active": false,
      "start": format.hex-address start,
      "end": format.hex-address end,
      "capacity-bytes": 0,
      "allocated-bytes": 0,
      "free-bytes": 0,
      "overhead-bytes": 0,
      "allocation-count": 0,
      "diagnostics": [],
    }
  if end <= start: throw "INVALID_ALLOCATOR_HEAP_DESCRIPTOR"
  heap-type := "struct multi_heap_info"
  number-of-pages := read-int32-field memory layout heap-type heap "number_of_pages"
  page-base := read-pointer-field memory layout heap-type heap "page_base"
  highest-address := read-pointer-field memory layout heap-type heap "highest_address"
  end-of-structure := read-pointer-field memory layout heap-type heap "end_of_heap_structure"
  if number-of-pages < 0 or number-of-pages > 1_000_000:
    throw "INVALID_ALLOCATOR_PAGE_COUNT"

  result := {
    "index": heap-index,
    "descriptor": format.hex-address descriptor,
    "active": true,
    "address": format.hex-address heap,
    "start": format.hex-address start,
    "end": format.hex-address end,
    "capacity-bytes": end - start,
    "page-base": format.hex-address page-base,
    "page-count": number-of-pages,
    "highest-address": format.hex-address highest-address,
    "allocated-bytes": 0,
    "free-bytes": 0,
    "overhead-bytes": max 0 (end-of-structure - heap),
    "allocation-count": 0,
    "diagnostics": [],
  }
  decode-pages memory layout heap heap-index page-base number-of-pages allocations result
  decode-arenas memory layout heap heap-index allocations result
  return result

decode-pages
    memory/target.Target
    layout/Map
    heap/int
    heap-index/int
    page-base/int
    page-count/int
    allocations/List
    result/Map
    -> none:
  pages-offset := runtime.layout-field-offset layout "struct multi_heap_info" "pages"
  page-size := type-size layout "Page"
  status-offset := runtime.layout-field-offset layout "Page" "status"
  tag-offset := runtime.layout-field-offset layout "Page" "tag"
  index := 0
  while index < page-count:
    entry := heap + pages-offset + index * page-size
    status := read-word memory (entry + status-offset)
    if status == PAGE-CONTINUED:
      result["diagnostics"].add {
        "code": "ALLOCATOR_ORPHAN_CONTINUATION_PAGE",
        "address": format.hex-address (page-base + index * PAGE-SIZE),
      }
      index++
      continue
    continuation := status == PAGE-FREE ? PAGE-FREE : PAGE-CONTINUED
    run := 1
    if status == PAGE-FREE or status == PAGE-IN-USE or
        status == PAGE-IN-USE-FOR-MALLOCS:
      while index + run < page-count:
        next-entry := heap + pages-offset + (index + run) * page-size
        if (read-word memory (next-entry + status-offset)) != continuation: break
        run++
    bytes := run * PAGE-SIZE
    address := page-base + index * PAGE-SIZE
    if status == PAGE-FREE:
      result["free-bytes"] += bytes
    else if status == PAGE-IN-USE:
      raw-tag := read-word memory (entry + tag-offset)
      allocations.add (allocation
          "allocator/$heap-index/page/$index"
          address
          bytes
          raw-tag
          (storage-at memory address)
          "compact-allocator-page")
      result["allocated-bytes"] += bytes
      result["allocation-count"] += 1
    else if status != PAGE-IN-USE-FOR-MALLOCS:
      result["diagnostics"].add {
        "code": "ALLOCATOR_INVALID_PAGE_STATUS",
        "address": format.hex-address address,
        "status": status,
      }
    index += run

decode-arenas
    memory/target.Target
    layout/Map
    heap/int
    heap-index/int
    allocations/List
    result/Map
    -> none:
  arenas-offset := runtime.layout-field-offset layout "struct multi_heap_info" "arenas"
  arena-next-offset := runtime.layout-field-offset layout "arena_t" "next"
  arena-size := type-size layout "arena_t"
  header-size := type-size layout "header_t"
  size-offset := runtime.layout-field-offset layout "header_t" "size_"
  tag-offset := runtime.layout-field-offset layout "header_t" "tag"
  sentinel := heap + arenas-offset
  arena := read-word memory (sentinel + arena-next-offset)
  visited := {}
  arena-count := 0
  allocation-count := 0
  while arena != sentinel and arena != 0 and arena-count < MAX-ARENAS:
    if visited.contains arena:
      result["diagnostics"].add (diagnostic "ALLOCATOR_ARENA_LIST_CYCLE" arena)
      break
    visited.add arena
    next-arena := read-word memory (arena + arena-next-offset)
    // Arena header, left sentinel, and terminal sentinel are allocator overhead.
    result["overhead-bytes"] += arena-size + 2 * header-size
    header := arena + arena-size + header-size
    while allocation-count < MAX-SMALL-ALLOCATIONS:
      size-field := read-word memory (header + size-offset)
      area-size := size-field >> 16
      if area-size == 0: break
      if area-size < header-size or (area-size & 7) != 0:
        result["diagnostics"].add {
          "code": "ALLOCATOR_INVALID_AREA_SIZE",
          "address": format.hex-address header,
          "size": area-size,
        }
        break
      payload := header + header-size
      payload-size := area-size - header-size
      result["overhead-bytes"] += header-size
      if (size-field & 1) != 0:
        result["free-bytes"] += payload-size
      else:
        raw-tag := read-word memory (header + tag-offset)
        allocations.add (allocation
            "allocator/$heap-index/small/$(format.hex-address header)"
            payload
            payload-size
            raw-tag
            (storage-at memory payload)
            "compact-allocator-small")
        result["allocated-bytes"] += payload-size
        result["allocation-count"] += 1
      header += area-size
      allocation-count++
    if allocation-count == MAX-SMALL-ALLOCATIONS:
      result["diagnostics"].add (diagnostic "ALLOCATOR_SMALL_ALLOCATION_LIMIT" header)
      break
    arena = next-arena
    arena-count++
  if arena-count == MAX-ARENAS and arena != sentinel:
    result["diagnostics"].add (diagnostic "ALLOCATOR_ARENA_LIST_LIMIT" arena)

allocation
    id/string address/int size/int raw-tag/int storage/string evidence/string
    -> Map:
  tag := describe-tag raw-tag
  return {
    "id": id,
    "address": format.hex-address address,
    "size": size,
    "kind": "native-allocation",
    "storage": storage,
    "origin-component": tag["component"],
    "allocator-tag": tag,
    "evidence": evidence,
  }

describe-tag raw/int -> Map:
  if raw == 0: return known-tag 13 "untagged" "untagged" raw
  if raw == 87: return known-tag 14 "wifi" "wifi" raw
  signed := raw >= 0x8000_0000 ? raw - 0x1_0000_0000 : raw
  id := signed - CUSTOM-TAG-BASE
  names := {
    0: ["misc", "native-runtime"],
    1: ["external-byte-array", "toit-external-objects"],
    2: ["tls/bignum", "crypto"],
    3: ["external-string", "toit-external-objects"],
    4: ["toit-processes", "toit-runtime"],
    7: ["lwip", "networking"],
    10: ["event-source", "event-sources"],
    11: ["thread/other", "threads"],
    12: ["thread/spawn", "threads"],
    14: ["wifi", "wifi"],
    15: ["bluetooth", "bluetooth"],
  }
  known := names.get id
  if known: return known-tag id known[0] known[1] raw
  return {
    "id": null,
    "name": "unknown",
    "component": "unknown",
    "raw": format.hex-address raw,
  }

known-tag id/int name/string component/string raw/int -> Map:
  return {
    "id": id,
    "name": name,
    "component": component,
    "raw": format.hex-address raw,
  }

allocator-summary heaps/List allocations/List -> Map:
  capacity := 0
  allocated := 0
  free := 0
  overhead := 0
  active-heaps := 0
  heaps.do: | heap/Map |
    if heap["active"]: active-heaps++
    capacity += heap["capacity-bytes"]
    allocated += heap["allocated-bytes"]
    free += heap["free-bytes"]
    overhead += heap["overhead-bytes"]
  return {
    "heap-count": heaps.size,
    "active-heap-count": active-heaps,
    "capacity-bytes": capacity,
    "allocated-payload-bytes": allocated,
    "free-bytes": free,
    "overhead-bytes": overhead,
    "allocation-count": allocations.size,
  }

storage-at memory/target.Target address/int -> string:
  memory.regions.do: | region/target.MemoryRegion |
    if address >= region.address and address < region.end-address:
      if region.kind == "external-ram" or region.kind == "psram":
        return "external-ram"
      return "ram"
  return "unknown"

read-pointer-field
    memory/target.Target layout/Map type/string address/int field/string
    -> int:
  return read-word memory
      (address + (runtime.layout-field-offset layout type field))

read-int32-field
    memory/target.Target layout/Map type/string address/int field/string
    -> int:
  value := read-pointer-field memory layout type address field
  return value >= 0x8000_0000 ? value - 0x1_0000_0000 : value

read-word memory/target.Target address/int -> int:
  bytes := memory.read address 4
  return bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24)

type-size layout/Map name/string -> int:
  types/Map := layout["types"]
  type/Map := types[name]
  return type["size"]

diagnostic code/string address/int -> Map:
  return {
    "code": code,
    "address": format.hex-address address,
  }
