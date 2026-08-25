// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

import crypto.sha256 as crypto
import io show LITTLE-ENDIAN

import .format as format
import .gc-state as gc-state
import .target as target
import .toit-model as toit-model

WORD-SIZE ::= 4
MAX-PREVIEW-BYTES ::= 64
MAX-SEARCH-PATTERN ::= 256
MAX-SEARCH-RESULTS ::= 1_000
SEARCH-READ-CHUNK ::= 64 * 1_024

TYPE-TAGS ::= [
  "array",
  "string",
  "instance",
  "oddball",
  "double",
  "byte-array",
  "large-integer",
  "stack",
  "task",
  "free-list-region",
  "single-free-word",
  "promoted-track",
]

PROCESS-STATES ::= [
  "idle",
  "scheduled",
  "running",
  "terminating",
  "suspended-idle",
  "suspended-scheduled",
  "suspended-awaiting-gc",
]

MAX-RUNTIME-LIST ::= 1_024
MAX-STACK-SLOTS ::= 16_384
MAX-HEAP-OBJECTS ::= 1_000_000
MAX-HEAP-RANGE ::= 64 * 1_024 * 1_024
MAX-OBJECT-EDGES ::= 65_536
MAX-RETENTION-NODES ::= 100_000
MAX-RETENTION-DEPTH ::= 1_024
MAX-PROCESS-ROOTS ::= 65_536
BLOCK-SALT ::= 0x0102_0304

decode-word capture/toit-model.View address/int -> Map:
  ensure-supported-layout capture
  raw := read-uint32 capture address
  result := {
    "address": format.hex-address address,
    "raw": hex-word raw,
    "evidence": "captured-memory",
  }
  tag := raw & 3
  if (raw & 1) == 0:
    result["candidate-kind"] = "smi"
    result["value"] = (signed-32 raw) >> 1
    result["display"] = "$(result["value"])"
  else if tag == 1:
    object-address := raw - 1
    result["candidate-kind"] = "heap-reference"
    result["object-address"] = format.hex-address object-address
    result["target-captured"] = is-captured capture object-address WORD-SIZE
    add-target-location capture result object-address
  else:
    object-address := raw & ~3
    result["candidate-kind"] = "marked-heap-reference"
    result["object-address"] = format.hex-address object-address
    result["unmarked-reference"] = hex-word (object-address + 1)
    result["target-captured"] = is-captured capture object-address WORD-SIZE
    add-target-location capture result object-address
  return result

add-target-location
    capture/toit-model.View result/Map target/int
    -> none:
  region := region-containing capture target
  if not region:
    storage := uncaptured-storage-for-address capture target
    result["target-storage"] = storage
    result["display"] = storage == "uncaptured"
        ? "$(format.hex-address target) (uncaptured)"
        : "$(format.hex-address target) ($storage, uncaptured)"
    return
  result["target-region"] = {
    "id": region.id,
    "name": region.name,
    "kind": region.kind,
    "permissions": region.permissions,
  }
  storage := storage-for-region region
  result["target-storage"] = storage
  result["display"] = "$(format.hex-address target) ($storage)"

region-containing capture/toit-model.View address/int -> target.MemoryRegion?:
  capture.regions.do: | region/target.MemoryRegion |
    if address >= region.address and address < region.end-address:
      return region
  return null

uncaptured-storage-for-address
    capture/toit-model.View address/int
    -> string:
  target-metadata/Map := capture.metadata.get "target" --if-absent=: {:}
  ranges/List := target-metadata.get
      "flash-mapped-data-ranges"
      --if-absent=: []
  ranges.do: | range/Map |
    start := format.parse-address range["start"]
    end := format.parse-address range["end"]
    if start <= address < end: return "flash"
  return "uncaptured"

storage-for-region region/target.MemoryRegion -> string:
  if region.kind == "flash-mapped-data" or
      region.kind == "program-heap":
    return "flash"
  if region.kind == "external-ram" or region.kind == "psram":
    return "external-ram"
  if region.kind == "rtc-ram": return "rtc-ram"
  if region.kind == "internal-ram" or
      region.kind == "word-only-internal-ram":
    return "ram"
  if region.permissions.contains "w": return "ram"
  return "read-only-memory"

decode-object capture/toit-model.View address/int -> Map:
  ensure-supported-layout capture
  raw-address := normalize-object-address address
  header := read-uint32 capture raw-address
  runtime-state := gc-state.describe capture.observation
  result := {
    "input-address": format.hex-address address,
    "address": format.hex-address raw-address,
    "tagged-reference": hex-word (raw-address + 1),
    "header": hex-word header,
    "evidence": "captured-memory",
    "runtime-state": runtime-state,
    "semantic-coherence": capture.metadata["completeness"].get
        "semantic-coherence"
        --if-absent=: false,
  }

  if (header & 3) == 1:
    destination := header - 1
    result["state"] = "forwarded"
    result["forwarding-reference"] = hex-word header
    result["forwarding-address"] = format.hex-address destination
    result["forwarding-target-captured"] = is-captured capture destination WORD-SIZE
    result["confidence"] = "exact-header"
    return result

  if (header & 1) != 0:
    result["state"] = "ambiguous-header"
    result["confidence"] = "low"
    result["diagnostics"] = ["HEADER_IS_NEITHER_SMI_NOR_FORWARDING_POINTER"]
    return result

  header-value := (signed-32 header) >> 1
  type-tag := header-value & 0xf
  class-id := header-value >> 5
  result["state"] = "normal-header"
  result["class-id"] = class-id
  result["type-tag"] = type-tag
  result["has-active-finalizer"] = (header-value & 0x10) != 0
  if type-tag < 0 or type-tag >= TYPE-TAGS.size:
    result["type"] = "unknown"
    result["confidence"] = "low"
    result["diagnostics"] = ["UNKNOWN_TYPE_TAG"]
    return result

  type := TYPE-TAGS[type-tag]
  result["type"] = type
  result["confidence"] = "structural"
  add-layout-evidence capture raw-address type result
  return result

decode-object-with-program
    capture/toit-model.View address/int program/int layout/Map
    -> Map:
  result := decode-object capture address
  if result["state"] != "normal-header": return result
  type/string := result["type"]
  if type == "stack":
    raw-address := normalize-object-address address
    length := read-uint32
        capture
        raw-address + (layout-constant layout "toit::Stack::LENGTH_OFFSET")
    result["length"] = length
    add-size-evidence
        capture
        raw-address
        aligned-size
            (layout-constant layout "toit::Stack::HEADER_SIZE") + length * WORD-SIZE
        result
    result["confidence"] = "exact-runtime-layout"
    result.remove "diagnostics"
    return result
  if type != "instance" and type != "task" and type != "oddball":
    return result
  class-id/int := result["class-id"]
  if class-id < 0: return result
  class-bits-offset := layout-field-offset layout "toit::Program" "class_bits"
  data-offset := layout-field-offset layout "toit::List<unsigned short>" "data_"
  length-offset := layout-field-offset layout "toit::List<unsigned short>" "length_"
  table := program + class-bits-offset
  data := read-pointer-if-captured capture (table + data-offset) [] "class-bits-data"
  length := read-int32-if-captured capture (table + length-offset) [] "class-bits-length"
  if not data or not length or class-id >= length:
    result["confidence"] = "layout-required"
    result["diagnostics"] = ["CLASS_BITS_NOT_CAPTURED"]
    return result
  class-bits := read-uint16-if-captured
      capture
      (data + class-id * 2)
      []
      "class-bits"
  if class-bits == null:
    result["confidence"] = "layout-required"
    result["diagnostics"] = ["CLASS_BITS_NOT_CAPTURED"]
    return result
  size := ((class-bits >> 5) & 0x7ff) * WORD-SIZE
  result["class-bits"] = "0x$(class-bits.to-string --radix=16)"
  result["size"] = size
  result["size-valid"] = size >= WORD-SIZE and
      is-captured capture (format.parse-address result["address"]) size
  result["confidence"] = "exact-program-class-bits"
  result.remove "diagnostics"
  if result["size-valid"]:
    field-count := (size - WORD-SIZE) / WORD-SIZE
    result["fields"] = preview-words
        capture
        (format.parse-address result["address"]) + WORD-SIZE
        field-count
    if type == "task" and field-count >= 2:
      result["stack"] = result["fields"][0]
      result["task-id"] = result["fields"][1]
  return result

heap-range-census
    capture/toit-model.View start/int end/int program/int layout/Map
    offset/int=0 limit/int=100
    --space-kind/string?=null
    -> Map:
  ensure-supported-layout capture
  validate-runtime-layout layout
  if start < 0 or end <= start or end - start > MAX-HEAP-RANGE:
    throw "INVALID_HEAP_RANGE"
  if offset < 0 or limit < 0 or limit > 500: throw "INVALID_PAGINATION"
  diagnostics := []
  type-counters := {:}
  class-counters := {:}
  liveness-counters := {:}
  items := []
  current := start
  object-count := 0
  object-bytes := 0
  free-bytes := 0
  external-bytes := 0
  captured-external-bytes := 0
  external-count := 0
  external-reference-count := 0
  seen-external := {}
  sentinel/int? := null
  program-layout := program-layout-for-program capture program layout
  runtime-state := gc-state.describe capture.observation
  phase-diagnostics := []
  if not runtime-state["normal-heap-census-safe"]:
    phase-diagnostics.add {
      "code": "NORMAL_HEAP_MODEL_NOT_AUTHORITATIVE",
      "phase": runtime-state["phase"],
      "checkpoint": runtime-state.get "checkpoint",
    }

  while current + WORD-SIZE <= end and object-count < MAX-HEAP-OBJECTS:
    if not is-captured capture current WORD-SIZE:
      add-runtime-diagnostic
          diagnostics
          "HEAP_HEADER_NOT_CAPTURED"
          current
          "heap-census"
      break
    header := read-uint32 capture current
    if header == 0:
      sentinel = current
      break
    object/Map? := null
    exception := catch:
      object = heap-walk-object capture current program layout header
    if exception:
      add-runtime-diagnostic
          diagnostics
          "HEAP_OBJECT_DECODE_FAILED"
          current
          "$exception"
      break
    size := object["size"]
    if not size is int or size <= 0 or (size & (WORD-SIZE - 1)) != 0 or
        current + size > end:
      add-runtime-diagnostic
          diagnostics
          "INVALID_HEAP_OBJECT_SIZE"
          current
          "heap-census"
      break

    type/string := object.get "type" --if-absent=: "unknown"
    is-free := type == "free-list-region" or type == "single-free-word"
    if is-free:
      free-bytes += size
    else:
      object-bytes += size
    account-census-entry type-counters type size

    class-id := object.get "class-id"
    class-info := class-info-for-id program-layout class-id
    if class-id is int and class-id >= 0:
      class-key := "$class-id"
      class-name := class-info
          ? class-info["name"]
          : "class-$class-id"
      account-class-entry
          class-counters
          class-key
          class-id
          class-name
          type
          size

    liveness := gc-liveness-for-object
        capture
        current
        object
        layout
        runtime-state
        space-kind
    if liveness:
      object["gc-liveness"] = liveness
      account-liveness-entry
          liveness-counters
          liveness["state"]
          size

    external-size := external-payload-size object
    if external-size > 0:
      external-reference-count++
      external-address := object.get "external-address"
      external-key := "$external-address:$external-size"
      if not seen-external.contains external-key:
        seen-external.add external-key
        external-count++
        external-bytes += external-size
        content-captured := object.get "external-content-captured" --if-absent=: false
        if content-captured:
          captured-external-bytes += external-size

    if object-count >= offset and items.size < limit:
      item := {
        "index": object-count,
        "address": format.hex-address current,
        "size": size,
        "state": object["state"],
        "type": type,
        "class-id": class-id,
        "free": is-free,
        "header": object["header"],
      }
      if class-info:
        item["class-name"] = class-info["name"]
        item["class-path"] = class-info["path"]
      if liveness: item["gc-liveness"] = liveness
      if object.contains "forwarding-address":
        item["forwarding-address"] = object["forwarding-address"]
      external := object.get "external" --if-absent=: false
      if external:
        item["external"] = true
        item["external-address"] = object.get "external-address"
        item["external-size"] = external-size
        item["external-content-captured"] =
            object.get "external-content-captured" --if-absent=: false
      items.add item
    current += size
    object-count++

  if object-count == MAX-HEAP-OBJECTS:
    add-runtime-diagnostic
        diagnostics
        "HEAP_OBJECT_LIST_LIMIT"
        current
        "heap-census"
  if not sentinel:
    add-runtime-diagnostic
        diagnostics
        "HEAP_SENTINEL_NOT_FOUND"
        current
        "heap-census"
  decoded-end := sentinel or current
  return {
    "start": format.hex-address start,
    "end": format.hex-address end,
    "range-bytes": end - start,
    "decoded-end": format.hex-address decoded-end,
    "sentinel-address": sentinel ? format.hex-address sentinel : null,
    "sentinel-bytes": sentinel ? WORD-SIZE : 0,
    "unused-after-sentinel-bytes": sentinel ? end - sentinel - WORD-SIZE : null,
    "object-count": object-count,
    "object-bytes": object-bytes,
    "free-bytes": free-bytes,
    "occupied-bytes": object-bytes + free-bytes,
    "external-payload-bytes": external-bytes,
    "captured-external-payload-bytes": captured-external-bytes,
    "external-payload-count": external-count,
    "external-payload-reference-count": external-reference-count,
    "by-type": type-counters.values,
    "by-class": class-counters.values,
    "by-gc-liveness": liveness-counters.values,
    "items": items,
    "offset": offset,
    "limit": limit,
    "total": object-count,
    "next-offset": offset + items.size < object-count
        ? offset + items.size
        : null,
    "diagnostics": diagnostics,
    "complete": sentinel != null and diagnostics.is-empty,
    "authoritative": sentinel != null and diagnostics.is-empty and
        runtime-state["normal-heap-census-safe"],
    "runtime-state": runtime-state,
    "space-view": space-kind
        ? gc-state.space-view runtime-state space-kind
        : null,
    "phase-diagnostics": phase-diagnostics,
  }

gc-liveness-for-object
    capture/toit-model.View
    address/int
    object/Map
    layout/Map
    runtime-state/Map
    space-kind/string?
    -> Map?:
  phase := runtime-state["phase"]
  checkpoint/Map? := runtime-state.get "checkpoint"
  boundary := checkpoint ? checkpoint.get "name" : null
  object-state := object["state"]
  if phase == "scavenge" and space-kind == "new-space":
    forwarded := object-state == "forwarded" or object-state == "marked-forwarding"
    state := forwarded
        ? "live-forwarded"
        : boundary == "scavenge-complete"
            ? "dead-unforwarded"
            : "unforwarded-unknown"
    return {
      "state": state,
      "evidence": forwarded ? "forwarding-header" : "checkpoint-boundary",
      "boundary": boundary,
    }

  if phase != "marking" and phase != "sweeping" and phase != "compacting":
    return null
  type := object.get "type"
  if type == "free-list-region" or type == "single-free-word": return null
  mark-evidence/Map? := null
  exception := catch:
    mark-evidence = read-gc-mark-bit capture address layout
  if exception:
    return {
      "state": "unknown",
      "evidence": "gc-metadata-unavailable",
      "diagnostic": "$exception",
    }
  marked := mark-evidence["marked"]
  state := boundary == "mark-after-roots"
      ? marked ? "reached-so-far" : "not-yet-reached"
      : marked ? "live" : "dead"
  mark-evidence["state"] = state
  mark-evidence["evidence"] = "gc-mark-bit"
  return mark-evidence

read-gc-mark-bit
    capture/toit-model.View address/int layout/Map
    -> Map:
  metadata := layout-symbol-address layout "toit::GcMetadata::singleton_"
  bias-address := metadata +
      (layout-field-offset layout "toit::GcMetadata" "mark_bits_bias_")
  if not is-captured capture bias-address WORD-SIZE:
    throw "GC_MARK_BITS_BIAS_NOT_CAPTURED"
  bias := read-uint32 capture bias-address
  // GcMetadata uses one bit per heap word and aligns reads to 32 bits.
  bits-address := (bias + (address >> 5)) & ~3
  if not is-captured capture bits-address WORD-SIZE:
    throw "GC_MARK_BITS_NOT_CAPTURED"
  bits := read-uint32 capture bits-address
  index := (address >> 2) & 31
  return {
    "marked": (bits & (1 << index)) != 0,
    "bit-index": index,
    "bitmap-address": format.hex-address bits-address,
  }

heap-walk-object
    capture/toit-model.View address/int program/int layout/Map header/int
    -> Map:
  object := decode-object-with-program capture address program layout
  if object["state"] == "normal-header":
    size-valid := object.get "size-valid" --if-absent=: false
    if size-valid: return object
    throw "HEAP_OBJECT_SIZE_NOT_CAPTURED"
  if object["state"] == "forwarded" or (header & 3) == 3:
    target := object["state"] == "forwarded"
        ? format.parse-address object["forwarding-address"]
        : header & ~3
    target-object := decode-object-with-program capture target program layout
    if target-object["state"] != "normal-header" or
        not (target-object.get "size-valid" --if-absent=: false):
      throw "FORWARDING_TARGET_SIZE_NOT_AVAILABLE"
    object["state"] = (header & 3) == 3 ? "marked-forwarding" : "forwarded"
    object["forwarding-address"] = format.hex-address target
    object["type"] = target-object["type"]
    object["class-id"] = target-object.get "class-id"
    object["size"] = target-object["size"]
    object["size-valid"] = true
    object["size-evidence"] = "forwarding-target"
    if target-object.contains "external": object["external"] = target-object["external"]
    if target-object.contains "length": object["length"] = target-object["length"]
    if target-object.contains "external-address":
      object["external-address"] = target-object["external-address"]
    if target-object.contains "external-tag":
      object["external-tag"] = target-object["external-tag"]
    if target-object.contains "external-content-captured":
      object["external-content-captured"] =
          target-object["external-content-captured"]
    return object
  throw "UNSUPPORTED_TRANSITIONAL_HEAP_HEADER"

program-layout-for-program
    capture/toit-model.View program/int layout/Map
    -> Map?:
  bytecodes-list := program + (layout-field-offset layout "toit::Program" "bytecodes")
  bytecodes-data := read-uint32-if-captured
      capture
      bytecodes-list + (layout-field-offset layout "toit::List<unsigned char>" "data_")
      []
      "program-bytecodes-data"
  bytecodes-length := read-uint32-if-captured
      capture
      bytecodes-list + (layout-field-offset layout "toit::List<unsigned char>" "length_")
      []
      "program-bytecodes-length"
  if not bytecodes-data or not bytecodes-length or
      not is-captured capture bytecodes-data bytecodes-length:
    return null
  sha := format.bytes-to-hex
      crypto.sha256 (capture.read bytecodes-data bytecodes-length)
  return matching-program-layout capture bytecodes-length sha

/** Resolves a program-relative BCI without exposing Program layout details. */
symbolize-program-bci
    capture/toit-model.View program/int layout/Map bci/int
    -> Map:
  program-layout := program-layout-for-program capture program layout
  if not program-layout:
    return {
      "bci": bci,
      "status": "unknown",
      "diagnostic": "PROGRAM_LAYOUT_NOT_AVAILABLE",
    }
  result := toit-model.symbolize-bci program-layout bci
  result["program"] = format.hex-address program
  return result

decorate-runtime-value
    capture/toit-model.View value/Map program/int layout/Map
    program-layout/Map?
    -> none:
  candidate := value.get "candidate-kind"
  if candidate != "heap-reference" and
      candidate != "marked-heap-reference":
    return
  if not (value.get "target-captured" --if-absent=: false): return
  address := format.parse-address value["object-address"]
  object/Map? := null
  exception := catch:
    object = decode-object-with-program capture address program layout
  if exception:
    value["object-diagnostic"] = "$exception"
    return
  class-info := class-info-for-id program-layout (object.get "class-id")
  class-name := class-info ? class-info.get "name" : null
  summary := {
    "address": object["address"],
    "state": object["state"],
    "type": object.get "type",
    "class-id": object.get "class-id",
    "class-name": class-name,
    "size": object.get "size",
  }
  if object.contains "length": summary["length"] = object["length"]
  if object.contains "content-preview":
    summary["content-preview"] = object["content-preview"]
    summary["preview-truncated"] =
        object.get "preview-truncated" --if-absent=: false
  value["object"] = summary
  object-type := object.get "type"
  label := class-name or object-type or "object"
  storage := value.get "target-storage" --if-absent=: "unknown-storage"
  value["display"] = "$label @ $(object["address"]) ($storage)"

class-info-for-id layout/Map? class-id/any -> Map?:
  if not layout or not class-id is int: return null
  classes/List := layout.get "classes" --if-absent=: []
  classes.do: | class-entry/Map |
    if class-entry["id"] == class-id: return class-entry
  return null

account-census-entry counters/Map key/string size/int -> none:
  entry/Map? := counters.get key
  if not entry:
    entry = {"type": key, "count": 0, "bytes": 0}
    counters[key] = entry
  entry["count"] += 1
  entry["bytes"] += size

account-class-entry
    counters/Map key/string id/int name/string type/string size/int
    -> none:
  entry/Map? := counters.get key
  if not entry:
    entry = {
      "class-id": id,
      "class-name": name,
      "type": type,
      "count": 0,
      "bytes": 0,
    }
    counters[key] = entry
  entry["count"] += 1
  entry["bytes"] += size

account-liveness-entry counters/Map state/string size/int -> none:
  entry/Map? := counters.get state
  if not entry:
    entry = {"state": state, "count": 0, "bytes": 0}
    counters[state] = entry
  entry["count"] += 1
  entry["bytes"] += size

external-payload-size object/Map -> int:
  if not (object.get "external" --if-absent=: false): return 0
  if object["type"] == "byte-array" and
      (object.get "external-tag" --if-absent=: 0) != 0:
    return 0
  length := object.get "length" --if-absent=: 0
  if not length is int or length <= 0: return 0
  return object["type"] == "string" ? length + 1 : length

object-edges
    capture/toit-model.View address/int program/int layout/Map
    offset/int=0 limit/int=100
    -> Map:
  ensure-supported-layout capture
  validate-runtime-layout layout
  if offset < 0 or limit <= 0 or limit > 500: throw "INVALID_PAGINATION"
  raw-address := normalize-object-address address
  object := decode-object-with-program capture raw-address program layout
  items := []
  state := {"total": 0, "scanned": 0, "scan-truncated": false}
  diagnostics := []
  program-layout := program-layout-for-program capture program layout
  if not program-layout: throw "PROGRAM_LAYOUT_NOT_AVAILABLE"

  if object["state"] == "forwarded":
    record-edge
        state
        items
        offset
        limit
        {
          "from": format.hex-address raw-address,
          "slot-address": format.hex-address raw-address,
          "offset": 0,
          "kind": "forwarding",
          "label": "forwarding-address",
          "raw": object["header"],
          "target": object["forwarding-address"],
          "target-captured": object["forwarding-target-captured"],
        }
  else if object["state"] == "normal-header":
    type/string := object["type"]
    if type == "array":
      scan-count := min object["length"] MAX-OBJECT-EDGES
      scan-count.repeat: | index |
        edge := pointer-edge-at
            capture
            raw-address
            raw-address + 8 + index * WORD-SIZE
            "element"
            "[$index]"
        if edge: record-edge state items offset limit edge
      state["scanned"] = scan-count
      if scan-count < object["length"]:
        state["scan-truncated"] = true
        diagnostics.add {
          "code": "OBJECT_EDGE_SCAN_LIMIT",
          "address": format.hex-address raw-address,
          "context": "array-elements",
        }
    else if type == "instance" or type == "task":
      size := object.get "size"
      if size is int and size >= WORD-SIZE:
        field-count := (size - WORD-SIZE) / WORD-SIZE
        class-info := class-info-for-id program-layout (object.get "class-id")
        field-names/List := class-info
            ? class-info.get "all-fields" --if-absent=: []
            : []
        field-count.repeat: | index |
          label := index < field-names.size ? field-names[index] : "field-$index"
          edge := pointer-edge-at
              capture
              raw-address
              raw-address + WORD-SIZE + index * WORD-SIZE
              "field"
              label
          if edge:
            edge["field-index"] = index
            record-edge state items offset limit edge
        state["scanned"] = field-count
    else if type == "stack":
      stack/Map? := null
      exception := catch: stack = decode-stack capture raw-address program layout
      if exception:
        diagnostics.add {
          "code": "STACK_EDGE_DECODE_FAILED",
          "address": format.hex-address raw-address,
          "context": "$exception",
        }
      else if stack["state"] == "published":
        unframed/List := stack["unframed-slots"]
        unframed.do: | slot/Map |
          edge := pointer-edge-from-stack-slot
              raw-address
              slot
              "unframed"
              "stack[$(slot["stack-index"])]"
          if edge: record-edge state items offset limit edge
          state["scanned"] += 1
        frames/List := stack["frames"]
        frames.do: | frame/Map |
          frame-index := frame["index"]
          slots/List := frame["slots"]
          slots.do: | slot/Map |
            role := slot.get "role" --if-absent=: "frame-value"
            name := slot.get "name"
            stack-index := slot["stack-index"]
            edge := pointer-edge-from-stack-slot
                raw-address
                slot
                "stack-slot"
                "frame-$frame-index.$(role)$(name ? ".$name" : "").stack-$stack-index"
            if edge:
              edge["frame-index"] = frame-index
              edge["stack-index"] = stack-index
              edge["role"] = role
              if name: edge["name"] = name
              if slot.contains "parameter-index":
                edge["parameter-index"] = slot["parameter-index"]
              if slot.contains "local-stack-height":
                edge["local-stack-height"] = slot["local-stack-height"]
              record-edge state items offset limit edge
            state["scanned"] += 1
      else:
        diagnostics.add {
          "code": "STACK_POINTERS_INTERPRETER_OWNED",
          "address": format.hex-address raw-address,
          "context": "object-edges",
        }

  total/int := state["total"]
  object-class-info := class-info-for-id program-layout (object.get "class-id")
  object-summary := {
    "address": object["address"],
    "state": object["state"],
    "type": object.get "type",
    "class-id": object.get "class-id",
    "class-name": object-class-info ? object-class-info["name"] : null,
    "size": object.get "size",
  }
  external-size := external-payload-size object
  if external-size > 0:
    object-summary["external-address"] = object.get "external-address"
    object-summary["external-size"] = external-size
    object-summary["external-content-captured"] =
        object.get "external-content-captured" --if-absent=: false
  return {
    "object": object-summary,
    "items": items,
    "offset": offset,
    "limit": limit,
    "total": total,
    "next-offset": offset + items.size < total ? offset + items.size : null,
    "scanned-slots": state["scanned"],
    "scan-truncated": state["scan-truncated"],
    "diagnostics": diagnostics,
  }

pointer-edge-at
    capture/toit-model.View from/int slot-address/int kind/string label/string
    -> Map?:
  value := decode-word capture slot-address
  candidate := value["candidate-kind"]
  if candidate != "heap-reference" and candidate != "marked-heap-reference":
    return null
  return {
    "from": format.hex-address from,
    "slot-address": format.hex-address slot-address,
    "offset": slot-address - from,
    "kind": kind,
    "label": label,
    "raw": value["raw"],
    "target": value["object-address"],
    "target-captured": value["target-captured"],
    "marked": candidate == "marked-heap-reference",
  }

pointer-edge-from-stack-slot
    from/int slot/Map kind/string label/string
    -> Map?:
  candidate := slot.get "candidate-kind"
  if candidate != "heap-reference" and candidate != "marked-heap-reference":
    return null
  slot-address := format.parse-address slot["address"]
  return {
    "from": format.hex-address from,
    "slot-address": slot["address"],
    "offset": slot-address - from,
    "kind": kind,
    "label": label,
    "raw": slot["raw"],
    "target": slot["object-address"],
    "target-captured": slot["target-captured"],
    "marked": candidate == "marked-heap-reference",
  }

record-edge state/Map items/List offset/int limit/int edge/Map -> none:
  total/int := state["total"]
  if total >= offset and items.size < limit: items.add edge
  state["total"] = total + 1

direct-retainers
    capture/toit-model.View start/int end/int program/int target/int layout/Map
    offset/int=0 limit/int=100
    -> Map:
  ensure-supported-layout capture
  validate-runtime-layout layout
  if start < 0 or end <= start or end - start > MAX-HEAP-RANGE:
    throw "INVALID_HEAP_RANGE"
  if offset < 0 or limit <= 0 or limit > 500: throw "INVALID_PAGINATION"
  target-address := format.hex-address (normalize-object-address target)
  items := []
  diagnostics := []
  current := start
  object-count := 0
  retainer-count := 0
  sentinel/int? := null
  complete := true

  while current + WORD-SIZE <= end and object-count < MAX-HEAP-OBJECTS:
    if not is-captured capture current WORD-SIZE:
      add-runtime-diagnostic
          diagnostics
          "HEAP_HEADER_NOT_CAPTURED"
          current
          "direct-retainers"
      complete = false
      break
    header := read-uint32 capture current
    if header == 0:
      sentinel = current
      break
    object/Map? := null
    exception := catch:
      object = heap-walk-object capture current program layout header
    if exception:
      add-runtime-diagnostic
          diagnostics
          "HEAP_OBJECT_DECODE_FAILED"
          current
          "$exception"
      complete = false
      break
    size/int := object["size"]
    if size <= 0 or (size & (WORD-SIZE - 1)) != 0 or current + size > end:
      add-runtime-diagnostic
          diagnostics
          "INVALID_HEAP_OBJECT_SIZE"
          current
          "direct-retainers"
      complete = false
      break

    edge-offset := 0
    while true:
      edge-page := object-edges capture current program layout edge-offset 500
      edges/List := edge-page["items"]
      edges.do: | edge/Map |
        if edge["target"] != target-address: continue.do
        if retainer-count >= offset and items.size < limit:
          items.add {
            "retainer": edge-page["object"],
            "edge": edge,
          }
        retainer-count++
      if edge-page["scan-truncated"]:
        diagnostics.add {
          "code": "RETAINER_EDGE_SCAN_INCOMPLETE",
          "address": format.hex-address current,
          "context": "direct-retainers",
        }
        complete = false
      next-edge := edge-page["next-offset"]
      if not next-edge: break
      edge-offset = next-edge
    current += size
    object-count++

  if object-count == MAX-HEAP-OBJECTS:
    add-runtime-diagnostic
        diagnostics
        "HEAP_OBJECT_LIST_LIMIT"
        current
        "direct-retainers"
    complete = false
  if not sentinel:
    add-runtime-diagnostic
        diagnostics
        "HEAP_SENTINEL_NOT_FOUND"
        current
        "direct-retainers"
    complete = false
  return {
    "target": target-address,
    "range": {
      "start": format.hex-address start,
      "end": format.hex-address end,
    },
    "scanned-object-count": object-count,
    "sentinel-address": sentinel ? format.hex-address sentinel : null,
    "items": items,
    "offset": offset,
    "limit": limit,
    "total": retainer-count,
    "next-offset": offset + items.size < retainer-count
        ? offset + items.size
        : null,
    "complete": complete and sentinel != null,
    "diagnostics": diagnostics,
  }

process-retention-path
    capture/toit-model.View object-heap-address/int target/int layout/Map
    max-nodes/int=10_000 max-depth/int=256
    -> Map:
  ensure-supported-layout capture
  validate-runtime-layout layout
  decoded-runtime := decode-runtime capture layout
  selected := find-process-by-object-heap decoded-runtime object-heap-address
  if not selected: throw "OBJECT_HEAP_NOT_FOUND"
  process/Map := selected["process"]
  object-heap/Map := process["object-heap"]
  program-value := object-heap.get "program"
  if not program-value: throw "PROCESS_PROGRAM_NOT_AVAILABLE"
  program := format.parse-address program-value
  ranges := process-heap-ranges object-heap
  if ranges.is-empty: throw "PROCESS_HEAP_RANGES_NOT_AVAILABLE"
  root-evidence := process-heap-roots capture object-heap-address program layout
  result := retention-path-from-roots
      capture
      ranges
      program
      root-evidence["items"]
      target
      layout
      max-nodes
      max-depth
  result["process-group-id"] = selected["process-group-id"]
  result["process-id"] = process["id"]
  if selected.get "container": result["container"] = selected["container"]
  result["object-heap"] = format.hex-address object-heap-address
  result["program"] = format.hex-address program
  result["root-set"] = root-set-summary root-evidence
  return result

root-set-summary evidence/Map -> Map:
  incomplete/List := evidence["incomplete-categories"]
  omitted/List := evidence["omitted-categories"]
  return {
    "decoded-categories": evidence["decoded-categories"],
    "not-applicable-categories": evidence["not-applicable-categories"],
    "incomplete-categories": incomplete,
    "omitted-categories": omitted,
    "complete": incomplete.is-empty and omitted.is-empty,
    "root-count": evidence["items"].size,
    "strong-root-count": evidence["strong-root-count"],
    "weak-root-count": evidence["weak-root-count"],
    "interpreter-register-roots": evidence["interpreter-register-roots"],
    "diagnostics": evidence["diagnostics"],
  }

process-retained-size
    capture/toit-model.View object-heap-address/int target/int layout/Map
    max-nodes/int=10_000 offset/int=0 limit/int=100
    -> Map:
  ensure-supported-layout capture
  validate-runtime-layout layout
  if offset < 0 or limit <= 0 or limit > 500: throw "INVALID_PAGINATION"
  decoded-runtime := decode-runtime capture layout
  selected := find-process-by-object-heap decoded-runtime object-heap-address
  if not selected: throw "OBJECT_HEAP_NOT_FOUND"
  process/Map := selected["process"]
  object-heap/Map := process["object-heap"]
  program-value := object-heap.get "program"
  if not program-value: throw "PROCESS_PROGRAM_NOT_AVAILABLE"
  program := format.parse-address program-value
  ranges := process-heap-ranges object-heap
  if ranges.is-empty: throw "PROCESS_HEAP_RANGES_NOT_AVAILABLE"
  roots := process-heap-roots capture object-heap-address program layout
  root-summary := root-set-summary roots
  full := reachable-from-strong-roots
      capture
      ranges
      program
      roots["items"]
      layout
      max-nodes
  target-address := normalize-object-address target
  target-key := format.hex-address target-address
  full-nodes/Map := full["nodes"]
  if not full-nodes.contains target-key:
    return {
      "status": "not-reachable-from-strong-roots",
      "target": target-key,
      "object-heap": format.hex-address object-heap-address,
      "program": format.hex-address program,
      "process-group-id": selected["process-group-id"],
      "process-id": process["id"],
      "container": selected.get "container",
      "root-set": root-summary,
      "graph": graph-summary full,
      "authoritative": root-summary["complete"] and full["complete"],
      "retained-object-count": 0,
      "retained-object-bytes": 0,
      "retained-external-payload-bytes": 0,
      "items": [],
      "offset": offset,
      "limit": limit,
      "total": 0,
      "next-offset": null,
    }
  without-target := reachable-from-strong-roots
      capture
      ranges
      program
      roots["items"]
      layout
      max-nodes
      target-address
  remaining/Map := without-target["nodes"]
  retained := []
  full-nodes.do: | key/string node/Map |
    if remaining.contains key: continue.do
    retained.add node
  accounting := object-list-accounting retained offset limit
  complete := full["complete"] and without-target["complete"]
  return {
    "status": "found",
    "target": target-key,
    "object-heap": format.hex-address object-heap-address,
    "program": format.hex-address program,
    "process-group-id": selected["process-group-id"],
    "process-id": process["id"],
    "container": selected.get "container",
    "root-set": root-summary,
    "graph": graph-summary full,
    "cut-graph": graph-summary without-target,
    "authoritative": root-summary["complete"] and complete,
    "retained-object-count": accounting["object-count"],
    "retained-object-bytes": accounting["object-bytes"],
    "retained-external-payload-bytes": accounting["external-payload-bytes"],
    "by-class": accounting["by-class"],
    "items": accounting["items"],
    "offset": offset,
    "limit": limit,
    "total": accounting["total"],
    "next-offset": accounting["next-offset"],
  }

process-transitive-size
    capture/toit-model.View object-heap-address/int target/int layout/Map
    max-nodes/int=10_000 offset/int=0 limit/int=100
    -> Map:
  ensure-supported-layout capture
  validate-runtime-layout layout
  if offset < 0 or limit <= 0 or limit > 500: throw "INVALID_PAGINATION"
  decoded-runtime := decode-runtime capture layout
  selected := find-process-by-object-heap decoded-runtime object-heap-address
  if not selected: throw "OBJECT_HEAP_NOT_FOUND"
  process/Map := selected["process"]
  object-heap/Map := process["object-heap"]
  program-value := object-heap.get "program"
  if not program-value: throw "PROCESS_PROGRAM_NOT_AVAILABLE"
  program := format.parse-address program-value
  ranges := process-heap-ranges object-heap
  if ranges.is-empty: throw "PROCESS_HEAP_RANGES_NOT_AVAILABLE"
  result := transitive-size-from-target
      capture
      ranges
      program
      target
      layout
      max-nodes
      offset
      limit
  result["object-heap"] = format.hex-address object-heap-address
  result["program"] = format.hex-address program
  result["process-group-id"] = selected["process-group-id"]
  result["process-id"] = process["id"]
  if selected.get "container": result["container"] = selected["container"]
  return result

transitive-size-from-target
    capture/toit-model.View ranges/List program/int target/int layout/Map
    max-nodes/int=10_000 offset/int=0 limit/int=100
    -> Map:
  if offset < 0 or limit <= 0 or limit > 500: throw "INVALID_PAGINATION"
  target-address := normalize-object-address target
  target-key := format.hex-address target-address
  if not address-in-ranges ranges target-address:
    return transitive-size-result
        "target-not-in-process-heap"
        target-key
        null
        offset
        limit
  graph := reachable-from-strong-roots
      capture
      ranges
      program
      [{
        "kind": "selected-value",
        "label": "selected variable",
        "target": target-key,
        "strength": "strong",
      }]
      layout
      max-nodes
  nodes/Map := graph["nodes"]
  if not nodes.contains target-key:
    return transitive-size-result
        "target-not-decoded"
        target-key
        graph
        offset
        limit
  return transitive-size-result "found" target-key graph offset limit

transitive-size-result
    status/string target/string graph/Map? offset/int limit/int
    -> Map:
  nodes/Map := graph ? graph["nodes"] : {:}
  objects := nodes.values
  accounting := object-list-accounting objects offset limit
  complete := graph ? graph["complete"] : true
  return {
    "status": status,
    "target": target,
    "semantics": "inclusive-reachable-closure",
    "includes-target": status == "found",
    "includes-shared-objects": true,
    "authoritative": complete,
    "graph": graph ? graph-summary graph : null,
    "transitive-object-count": accounting["object-count"],
    "transitive-object-bytes": accounting["object-bytes"],
    "transitive-external-payload-bytes": accounting["external-payload-bytes"],
    "by-class": accounting["by-class"],
    "items": accounting["items"],
    "offset": offset,
    "limit": limit,
    "total": accounting["total"],
    "next-offset": accounting["next-offset"],
  }

object-list-accounting objects/List offset/int limit/int -> Map:
  object-bytes := 0
  external-bytes := 0
  external-payloads := {}
  class-counters := {:}
  objects.do: | node/Map |
    size := node.get "size" --if-absent=: 0
    if size is int: object-bytes += size
    external-size := node.get "external-size" --if-absent=: 0
    external-address := node.get "external-address"
    if external-size is int and external-size > 0 and external-address:
      external-key := "$external-address:$external-size"
      if not external-payloads.contains external-key:
        external-payloads.add external-key
        external-bytes += external-size
    class-id := node.get "class-id"
    if class-id is int:
      class-name := node.get "class-name" --if-absent=: "class-$class-id"
      if not class-name: class-name = "class-$class-id"
      account-class-entry
          class-counters
          "$class-id"
          class-id
          class-name
          node.get "type" --if-absent=: "unknown"
          size
  end := min objects.size (offset + limit)
  items := offset < objects.size ? objects[offset..end] : []
  return {
    "object-count": objects.size,
    "object-bytes": object-bytes,
    "external-payload-bytes": external-bytes,
    "by-class": class-counters.values,
    "items": items,
    "total": objects.size,
    "next-offset": end < objects.size ? end : null,
  }

reachable-from-strong-roots
    capture/toit-model.View ranges/List program/int roots/List layout/Map
    max-nodes/int blocked/int?=null
    -> Map:
  if max-nodes <= 0 or max-nodes > MAX-RETENTION-NODES:
    throw "INVALID_RETENTION_NODE_LIMIT"
  blocked-key := blocked == null ? null : format.hex-address blocked
  queue := []
  visited := {}
  nodes := {:}
  diagnostics := []
  node-limit-reached := false
  decode-failed := false
  roots.do: | root/Map |
    if (root.get "strength" --if-absent=: "strong") != "strong":
      continue.do
    key/string := root["target"]
    if key == blocked-key or visited.contains key: continue.do
    address := format.parse-address key
    if not address-in-ranges ranges address: continue.do
    if visited.size == max-nodes:
      node-limit-reached = true
      continue.do
    visited.add key
    queue.add address
  cursor := 0
  while cursor < queue.size:
    current/int := queue[cursor]
    cursor++
    current-key := format.hex-address current
    edge-offset := 0
    while true:
      page/Map? := null
      exception := catch:
        page = object-edges capture current program layout edge-offset 500
      if exception:
        add-runtime-diagnostic
            diagnostics
            "RETAINED_SIZE_OBJECT_DECODE_FAILED"
            current
            "$exception"
        decode-failed = true
        break
      if edge-offset == 0: nodes[current-key] = page["object"]
      edges/List := page["items"]
      edges.do: | edge/Map |
        key/string := edge["target"]
        if key == blocked-key or visited.contains key: continue.do
        address := format.parse-address key
        if not address-in-ranges ranges address: continue.do
        if visited.size == max-nodes:
          node-limit-reached = true
          continue.do
        visited.add key
        queue.add address
      if page["scan-truncated"]:
        add-runtime-diagnostic
            diagnostics
            "RETAINED_SIZE_EDGE_SCAN_INCOMPLETE"
            current
            "retained-size"
        decode-failed = true
      next-offset := page["next-offset"]
      if not next-offset: break
      edge-offset = next-offset
  return {
    "nodes": nodes,
    "complete": not node-limit-reached and not decode-failed,
    "node-limit-reached": node-limit-reached,
    "visited-object-count": visited.size,
    "decoded-object-count": nodes.size,
    "diagnostics": diagnostics,
  }

graph-summary graph/Map -> Map:
  return {
    "complete": graph["complete"],
    "node-limit-reached": graph["node-limit-reached"],
    "visited-object-count": graph["visited-object-count"],
    "decoded-object-count": graph["decoded-object-count"],
    "diagnostics": graph["diagnostics"],
  }

find-process-by-object-heap decoded-runtime/Map address/int -> Map?:
  groups/List := decoded-runtime.get "process-groups" --if-absent=: []
  groups.do: | group/Map |
    processes/List := group.get "processes" --if-absent=: []
    processes.do: | process/Map |
      object-heap/Map? := process.get "object-heap"
      if not object-heap: continue.do
      heap-address := object-heap.get "address"
      if heap-address and (format.parse-address heap-address) == address:
        return {
          "process-group-id": group["id"],
          "container": group.get "container",
          "process": process,
        }
  return null

process-heap-ranges object-heap/Map -> List:
  result := []
  ["old-space", "new-space"].do: | space-name/string |
    space/Map? := object-heap.get space-name
    if not space: continue.do
    chunks/List := space.get "chunks" --if-absent=: []
    chunks.do: | chunk/Map |
      start := chunk.get "start"
      end := chunk.get "end"
      if not start or not end: continue.do
      result.add {
        "space": space-name,
        "start": format.parse-address start,
        "end": format.parse-address end,
      }
  return result

process-heap-roots
    capture/toit-model.View object-heap/int program/int layout/Map
    -> Map:
  diagnostics := []
  roots := []
  decoded-categories := ["task", "global-variables"]
  incomplete-categories := []
  omitted-categories := []
  not-applicable-categories := []
  task-slot := object-heap +
      (layout-field-offset layout "toit::ObjectHeap" "task_")
  add-process-root capture roots task-slot "task" "task"

  globals := read-pointer-if-captured
      capture
      object-heap +
          (layout-field-offset layout "toit::ObjectHeap" "global_variables_")
      diagnostics
      "global-variables"
  if globals:
    table := program +
        (layout-field-offset layout "toit::Program" "global_variables")
    length := read-int32-if-captured
        capture
        table +
            (layout-field-offset
                layout
                "toit::Program::Table<toit::Object*>"
                "length_")
        diagnostics
        "global-variable-count"
    if length != null:
      if length < 0 or length > MAX-PROCESS-ROOTS:
        add-runtime-diagnostic
            diagnostics
            "INVALID_GLOBAL_VARIABLE_COUNT"
            table
            "process-roots"
      else:
        program-layout := program-layout-for-program capture program layout
        length.repeat: | index |
          label := global-name-for-index program-layout index
          add-process-root
              capture
              roots
              globals + index * WORD-SIZE
              "global"
              label

  notifier-complete := false
  notifier-exception := catch:
    notifier-complete = add-double-linked-process-roots
        capture
        layout
        roots
        diagnostics
        object-heap +
            (layout-field-offset
                layout
                "toit::ObjectHeap"
                "object_notifiers_")
        "DoubleLinkedListElement<toit::ObjectNotifier, 1>"
        layout-constant
            layout
            "toit::ObjectNotifier::HEAP_LIST_ELEMENT_OFFSET"
        "toit::ObjectNotifier"
        "object_"
        "object-notifier"
  if notifier-exception:
    omitted-categories.add "object-notifiers"
    add-runtime-diagnostic
        diagnostics
        "OBJECT_NOTIFIER_ROOTS_NOT_DECODED"
        object-heap
        "$notifier-exception"
  else if notifier-complete:
    decoded-categories.add "object-notifiers"
  else:
    incomplete-categories.add "object-notifiers"

  external-complete := false
  external-exception := catch:
    external-complete = add-double-linked-process-roots
        capture
        layout
        roots
        diagnostics
        object-heap +
            (layout-field-offset layout "toit::ObjectHeap" "external_roots_")
        "DoubleLinkedListElement<toit::HeapRoot, 1>"
        layout-constant layout "toit::HeapRoot::HEAP_LIST_ELEMENT_OFFSET"
        "toit::HeapRoot"
        "obj_"
        "external-root"
  if external-exception:
    omitted-categories.add "external-roots"
    add-runtime-diagnostic
        diagnostics
        "EXTERNAL_ROOTS_NOT_DECODED"
        object-heap
        "$external-exception"
  else if external-complete:
    decoded-categories.add "external-roots"
  else:
    incomplete-categories.add "external-roots"

  finalizers-complete := true
  finalizer-exception := catch:
    [
      ["runnable-finalizer", "runnable_finalizers_"],
      ["registered-callback-finalizer", "registered_callback_finalizers_"],
      ["registered-vm-finalizer", "registered_vm_finalizers_"],
    ].do: | names/List |
      queue-complete := add-finalizer-roots
          capture
          layout
          roots
          diagnostics
          object-heap +
              (layout-field-offset layout "toit::ObjectHeap" names[1])
          names[0]
      if not queue-complete: finalizers-complete = false
  if finalizer-exception:
    omitted-categories.add "finalizers"
    add-runtime-diagnostic
        diagnostics
        "FINALIZER_ROOTS_NOT_DECODED"
        object-heap
        "$finalizer-exception"
  else if finalizers-complete:
    decoded-categories.add "finalizers"
  else:
    incomplete-categories.add "finalizers"

  interpreter-state := classify-interpreter-register-roots
      capture
      object-heap
      program
      layout
      diagnostics
  if interpreter-state["state"] == "not-applicable":
    not-applicable-categories.add "active-interpreter-registers"
  else if interpreter-state["state"] == "required":
    omitted-categories.add "active-interpreter-registers"
  else:
    incomplete-categories.add "active-interpreter-registers"

  strong-root-count := 0
  weak-root-count := 0
  roots.do: | root/Map |
    if root["strength"] == "strong":
      strong-root-count++
    else:
      weak-root-count++

  return {
    "items": roots,
    "decoded-categories": decoded-categories,
    "not-applicable-categories": not-applicable-categories,
    "incomplete-categories": incomplete-categories,
    "omitted-categories": omitted-categories,
    "strong-root-count": strong-root-count,
    "weak-root-count": weak-root-count,
    "interpreter-register-roots": interpreter-state,
    "diagnostics": diagnostics,
  }

decode-process-globals
    capture/toit-model.View object-heap/int program/int layout/Map
    -> Map:
  diagnostics := []
  items := []
  program-layout := program-layout-for-program capture program layout
  metadata := program-layout-metadata capture program-layout
  globals := read-pointer-if-captured
      capture
      object-heap +
          (layout-field-offset layout "toit::ObjectHeap" "global_variables_")
      diagnostics
      "global-variables"
  if not globals:
    return {
      "items": items,
      "total": 0,
      "program-layout": metadata,
      "diagnostics": diagnostics,
      "complete": diagnostics.is-empty,
    }

  table := program +
      (layout-field-offset layout "toit::Program" "global_variables")
  length := read-int32-if-captured
      capture
      table +
          (layout-field-offset
              layout
              "toit::Program::Table<toit::Object*>"
              "length_")
      diagnostics
      "global-variable-count"
  if length == null:
    return {
      "items": items,
      "total": null,
      "table-address": format.hex-address globals,
      "program-layout": metadata,
      "diagnostics": diagnostics,
      "complete": false,
    }
  if length < 0 or length > MAX-PROCESS-ROOTS:
    add-runtime-diagnostic
        diagnostics
        "INVALID_GLOBAL_VARIABLE_COUNT"
        table
        "process-globals"
    return {
      "items": items,
      "total": length,
      "table-address": format.hex-address globals,
      "program-layout": metadata,
      "diagnostics": diagnostics,
      "complete": false,
    }

  length.repeat: | index |
    slot-address := globals + index * WORD-SIZE
    value/Map? := null
    exception := catch: value = decode-word capture slot-address
    if exception:
      add-runtime-diagnostic
          diagnostics
          "GLOBAL_VALUE_NOT_CAPTURED"
          slot-address
          "global-$index"
      continue.repeat
    info := global-info-for-index program-layout index
    value["index"] = index
    value["name"] = info ? info["name"] : "global-$index"
    value["qualified-name"] = global-name-for-index program-layout index
    value["name-confidence"] = info ? "snapshot-source-map" : "index-only"
    if info:
      value["holder-id"] = info.get "holder-id"
      value["holder-name"] = info.get "holder-name"
    candidate := value["candidate-kind"]
    root-reference := candidate == "heap-reference" or
        candidate == "marked-heap-reference"
    value["root-reference"] = root-reference
    storage := value.get "target-storage"
    value["keeps-alive"] = root-reference and
        storage != "flash" and storage != "read-only-memory"
    decorate-runtime-value capture value program layout program-layout
    items.add value
  return {
    "items": items,
    "total": length,
    "table-address": format.hex-address globals,
    "program-layout": metadata,
    "diagnostics": diagnostics,
    "complete": items.size == length and diagnostics.is-empty,
  }

program-layout-metadata capture/toit-model.View program-layout/Map? -> Map:
  if program-layout:
    version := program-layout["format-version"]
    frame-debug-available := program-layout-has-frame-debug program-layout
    result := {
      "state": "matched",
      "format-version": version,
      "source-snapshot-attachment-id":
          program-layout.get "source-snapshot-attachment-id",
      "source-snapshot-sha256":
          program-layout.get "source-snapshot-sha256",
      "global-names-available": true,
      "frame-variable-names-available": frame-debug-available,
    }
    if not frame-debug-available:
      result["frame-variable-names-reason"] =
          "FRAME_DEBUG_METADATA_NOT_AVAILABLE"
    return result
  layouts/List := capture.metadata.get "program-layouts" --if-absent=: []
  return {
    "state": "unavailable",
    "reason": layouts.is-empty
        ? "PROGRAM_LAYOUT_NOT_AVAILABLE"
        : "PROGRAM_BYTECODES_UNMATCHED",
    "global-names-available": false,
    "frame-variable-names-available": false,
  }

program-layout-has-frame-debug program-layout/Map -> bool:
  if program-layout["format-version"] < 2: return false
  methods/List := program-layout.get "methods" --if-absent=: []
  methods.do: | method/Map |
    if method.contains "parameters" and method.contains "locals": return true
  return false

global-info-for-index program-layout/Map? index/int -> Map?:
  if not program-layout: return null
  globals/List := program-layout.get "globals" --if-absent=: []
  if index < 0 or index >= globals.size: return null
  return globals[index]

classify-interpreter-register-roots
    capture/toit-model.View object-heap/int program/int layout/Map diagnostics/List
    -> Map:
  task-slot := object-heap +
      (layout-field-offset layout "toit::ObjectHeap" "task_")
  task-word/Map? := null
  exception := catch: task-word = decode-word capture task-slot
  if exception:
    return {"state": "unknown", "reason": "TASK_ROOT_NOT_CAPTURED"}
  candidate := task-word["candidate-kind"]
  if candidate != "heap-reference" and candidate != "marked-heap-reference":
    return {"state": "not-applicable", "reason": "NO_HEAP_TASK"}
  task-address := format.parse-address task-word["object-address"]
  task/Map? := null
  exception = catch:
    task = decode-object-with-program capture task-address program layout
  if exception or task["type"] != "task":
    return {"state": "unknown", "reason": "TASK_OBJECT_NOT_DECODED"}
  stack-word/Map? := task.get "stack"
  if not stack-word:
    return {"state": "unknown", "reason": "TASK_STACK_FIELD_NOT_DECODED"}
  stack-address-value := stack-word.get "object-address"
  if not stack-address-value:
    return {"state": "unknown", "reason": "TASK_HAS_NO_HEAP_STACK"}
  stack-address := format.parse-address stack-address-value
  stack-state := classify-stack-register-roots
      capture
      stack-address
      program
      layout
  stack-state["stack"] = format.hex-address stack-address
  return stack-state

classify-stack-register-roots
    capture/toit-model.View stack/int program/int layout/Map
    -> Map:
  decoded/Map? := null
  exception := catch: decoded = decode-stack capture stack program layout
  if exception:
    return {
      "state": "unknown",
      "reason": "STACK_NOT_DECODED",
      "context": "$exception",
    }
  if decoded["state"] == "published":
    return {
      "state": "not-applicable",
      "reason": "STACK_STATE_PUBLISHED_IN_HEAP",
    }
  if decoded["state"] == "interpreter-owned":
    return {
      "state": "required",
      "reason": "STACK_TOP_OWNED_BY_ACTIVE_INTERPRETER",
    }
  return {"state": "unknown", "reason": "UNRECOGNIZED_STACK_STATE"}

add-double-linked-process-roots
    capture/toit-model.View layout/Map roots/List diagnostics/List anchor/int
    element-type/string element-offset/int container-type/string
    value-field/string kind/string
    -> bool:
  next-offset := layout-field-offset layout element-type "next_"
  value-offset := layout-field-offset layout container-type value-field
  next := read-pointer-if-captured
      capture
      anchor + next-offset
      diagnostics
      "$(kind)-anchor"
  seen := {}
  count := 0
  while next and next != anchor and count < MAX-PROCESS-ROOTS:
    if seen.contains next:
      add-runtime-diagnostic diagnostics "ROOT_LIST_CYCLE" next kind
      return false
    seen.add next
    container := next - element-offset
    add-process-root
        capture
        roots
        container + value-offset
        kind
        "$(kind)-$count"
    next = read-pointer-if-captured
        capture
        next + next-offset
        diagnostics
        "$(kind)-next"
    count++
  if count == MAX-PROCESS-ROOTS:
    add-runtime-diagnostic diagnostics "ROOT_LIST_LIMIT" anchor kind
    return false
  else if not next:
    add-runtime-diagnostic diagnostics "ROOT_LIST_NULL_LINK" anchor kind
    return false
  return true

add-finalizer-roots
    capture/toit-model.View layout/Map roots/List diagnostics/List
    list-address/int kind/string
    -> bool:
  element-type := "LinkedListElement<toit::FinalizerNode, 1>"
  next-offset := layout-field-offset layout element-type "next_"
  element-offset := layout-constant
      layout
      "toit::FinalizerNode::HEAP_LIST_ELEMENT_OFFSET"
  key-offset := layout-field-offset layout "toit::FinalizerNode" "key_"
  lambda-offset := layout-field-offset
      layout
      "toit::CallableFinalizerNode"
      "lambda_"
  if not is-captured capture list-address WORD-SIZE:
    add-runtime-diagnostic
        diagnostics
        "RUNTIME_WORD_NOT_CAPTURED"
        list-address
        "$(kind)-anchor"
    return false
  next := read-uint32 capture list-address
  seen := {}
  count := 0
  complete := true
  while next != 0 and count < MAX-PROCESS-ROOTS:
    if seen.contains next:
      add-runtime-diagnostic diagnostics "ROOT_LIST_CYCLE" next kind
      return false
    seen.add next
    container := next - element-offset
    vtable/int? := null
    if is-captured capture container WORD-SIZE:
      vtable = read-uint32 capture container
    else:
      add-runtime-diagnostic
          diagnostics
          "RUNTIME_WORD_NOT_CAPTURED"
          container
          "$(kind)-vtable"
      complete = false
    dynamic-type := vtable ? dynamic-type-for-vtable layout vtable : null
    key-strength := kind == "runnable-finalizer" ? "strong" : "weak"
    key-complete := add-process-root
        capture
        roots
        container + key-offset
        kind
        "$(kind)-$(count).key"
        key-strength
    if not key-complete: complete = false
    if dynamic-type == "toit::WeakMapFinalizerNode" or
        dynamic-type == "toit::ToitFinalizerNode":
      lambda-complete := add-process-root
          capture
          roots
          container + lambda-offset
          kind
          "$(kind)-$(count).lambda"
      if not lambda-complete: complete = false
    else if dynamic-type != "toit::VmFinalizerNode":
      add-runtime-diagnostic
          diagnostics
          "UNKNOWN_FINALIZER_DYNAMIC_TYPE"
          container
          dynamic-type or "unknown"
      complete = false
    next-address := next + next-offset
    if not is-captured capture next-address WORD-SIZE:
      add-runtime-diagnostic
          diagnostics
          "RUNTIME_WORD_NOT_CAPTURED"
          next-address
          "$(kind)-next"
      return false
    next = read-uint32 capture next-address
    count++
  if count == MAX-PROCESS-ROOTS:
    add-runtime-diagnostic diagnostics "ROOT_LIST_LIMIT" list-address kind
    return false
  return complete

dynamic-type-for-vtable layout/Map address/int -> string?:
  vtables/List := layout.get "vtables" --if-absent=: []
  vtables.do: | entry/Map |
    address-point := entry.get "address-point"
    if address-point and (format.parse-address address-point) == address:
      return entry["name"]
  return null

add-process-root
    capture/toit-model.View roots/List slot-address/int kind/string label/string
    strength/string="strong"
    -> bool:
  value/Map? := null
  exception := catch: value = decode-word capture slot-address
  if exception: return false
  candidate := value["candidate-kind"]
  if candidate != "heap-reference" and candidate != "marked-heap-reference":
    return true
  roots.add {
    "kind": kind,
    "label": label,
    "slot-address": format.hex-address slot-address,
    "raw": value["raw"],
    "target": value["object-address"],
    "target-captured": value["target-captured"],
    "marked": candidate == "marked-heap-reference",
    "strength": strength,
  }
  return true

global-name-for-index program-layout/Map? index/int -> string:
  if program-layout:
    globals/List := program-layout.get "globals" --if-absent=: []
    if index < globals.size:
      info/Map := globals[index]
      holder := info.get "holder-name"
      return holder ? "$holder.$(info["name"])" : info["name"]
  return "global-$index"

retention-path-from-roots
    capture/toit-model.View ranges/List program/int roots/List target/int layout/Map
    max-nodes/int=10_000 max-depth/int=256
    -> Map:
  if max-nodes <= 0 or max-nodes > MAX-RETENTION-NODES:
    throw "INVALID_RETENTION_NODE_LIMIT"
  if max-depth < 0 or max-depth > MAX-RETENTION-DEPTH:
    throw "INVALID_RETENTION_DEPTH_LIMIT"
  target-address := normalize-object-address target
  target-key := format.hex-address target-address
  diagnostics := []
  if not address-in-ranges ranges target-address:
    return {
      "status": "target-outside-process-heap",
      "target": target-key,
      "path": null,
      "visited-object-count": 0,
      "max-nodes": max-nodes,
      "max-depth": max-depth,
      "search-complete": true,
      "diagnostics": diagnostics,
    }

  queue := []
  visited := {:}
  roots.do: | root/Map |
    if (root.get "strength" --if-absent=: "strong") != "strong":
      continue.do
    root-address := format.parse-address root["target"]
    if not address-in-ranges ranges root-address: continue.do
    key := format.hex-address root-address
    if visited.contains key: continue.do
    if visited.size == max-nodes: continue.do
    visited[key] = {
      "parent": null,
      "edge": null,
      "root": root,
      "depth": 0,
    }
    queue.add root-address

  found := visited.contains target-key
  cursor := 0
  node-limit-reached := false
  depth-limit-reached := false
  decode-failed := false
  while not found and cursor < queue.size:
    current/int := queue[cursor]
    cursor++
    current-key := format.hex-address current
    current-record/Map := visited[current-key]
    depth/int := current-record["depth"]
    if depth >= max-depth:
      depth-limit-reached = true
      continue
    edge-offset := 0
    while not found:
      edge-page/Map? := null
      exception := catch:
        edge-page = object-edges capture current program layout edge-offset 500
      if exception:
        add-runtime-diagnostic
            diagnostics
            "RETENTION_OBJECT_DECODE_FAILED"
            current
            "$exception"
        decode-failed = true
        break
      edges/List := edge-page["items"]
      edges.do: | edge/Map |
        if found: continue.do
        edge-target := format.parse-address edge["target"]
        if not address-in-ranges ranges edge-target: continue.do
        key := format.hex-address edge-target
        if visited.contains key: continue.do
        if visited.size == max-nodes:
          node-limit-reached = true
          continue.do
        visited[key] = {
          "parent": current-key,
          "edge": edge,
          "root": current-record["root"],
          "depth": depth + 1,
        }
        queue.add edge-target
        if key == target-key: found = true
      if edge-page["scan-truncated"]:
        add-runtime-diagnostic
            diagnostics
            "RETENTION_EDGE_SCAN_INCOMPLETE"
            current
            "retention-path"
        decode-failed = true
      next-offset := edge-page["next-offset"]
      if found or not next-offset: break
      edge-offset = next-offset

  search-complete := not node-limit-reached and
      not depth-limit-reached and
      not decode-failed
  status := found
      ? "found"
      : search-complete
          ? "not-found-in-decoded-root-graph"
          : "incomplete"
  return {
    "status": status,
    "target": target-key,
    "path": found ? build-retention-path visited target-key : null,
    "visited-object-count": visited.size,
    "max-nodes": max-nodes,
    "max-depth": max-depth,
    "search-complete": search-complete,
    "node-limit-reached": node-limit-reached,
    "depth-limit-reached": depth-limit-reached,
    "diagnostics": diagnostics,
  }

address-in-ranges ranges/List address/int -> bool:
  ranges.do: | range/Map |
    if address >= range["start"] and address < range["end"]: return true
  return false

build-retention-path visited/Map target-key/string -> Map:
  edges := []
  key := target-key
  record/Map := visited[key]
  root/Map := record["root"]
  while record["parent"]:
    edges.add record["edge"]
    key = record["parent"]
    record = visited[key]
  ordered-edges := []
  edges.do --reversed: ordered-edges.add it
  return {
    "root": root,
    "edges": ordered-edges,
    "length": ordered-edges.size,
  }

decode-stack
    capture/toit-model.View address/int program/int layout/Map
    -> Map:
  ensure-supported-layout capture
  validate-runtime-layout layout
  raw-address := normalize-object-address address
  object := decode-object capture raw-address
  if object["state"] != "normal-header" or object["type"] != "stack":
    throw "NOT_STACK_OBJECT"

  header-size := layout-constant layout "toit::Stack::HEADER_SIZE"
  length := read-uint32
      capture
      raw-address + (layout-constant layout "toit::Stack::LENGTH_OFFSET")
  top := read-int32
      capture
      raw-address + (layout-constant layout "toit::Stack::TOP_OFFSET")
  try-top := read-int32
      capture
      raw-address + (layout-constant layout "toit::Stack::TRY_TOP_OFFSET")
  pending := read-uint32
      capture
      raw-address +
          (layout-constant layout "toit::Stack::PENDING_STACK_CHECK_METHOD_OFFSET")
  size := aligned-size header-size + length * WORD-SIZE
  if not is-captured capture raw-address size: throw "STACK_NOT_CAPTURED"
  base-result := {
    "address": format.hex-address raw-address,
    "tagged-reference": hex-word (raw-address + 1),
    "evidence": "captured-memory+elf-runtime-layout",
    "semantic-coherence": capture.metadata["completeness"].get
        "semantic-coherence"
        --if-absent=: false,
    "length": length,
    "top": top == -1 ? null : top,
    "try-top": try-top,
    "size": size,
    "size-valid": true,
    "pending-stack-check-method": pending == 0
        ? null
        : format.hex-address pending,
    "program": format.hex-address program,
    "local-names-available": false,
  }
  if top == -1:
    base-result["state"] = "interpreter-owned"
    base-result["used-slots"] = null
    base-result["frame-count"] = null
    base-result["frames"] = []
    base-result["unframed-slots"] = []
    base-result["diagnostics"] = ["STACK_TOP_OWNED_BY_ACTIVE_INTERPRETER"]
    return base-result
  if top < 0 or top > length or try-top < 0 or try-top > length:
    throw "INVALID_STACK_BOUNDS"
  used := length - top
  if used > MAX-STACK-SLOTS: throw "STACK_SLOT_LIMIT"

  bytecodes-offset := layout-field-offset layout "toit::Program" "bytecodes"
  bytecodes-list := program + bytecodes-offset
  bytecodes-data := read-uint32
      capture
      bytecodes-list +
          (layout-field-offset layout "toit::List<unsigned char>" "data_")
  bytecodes-length := read-uint32
      capture
      bytecodes-list +
          (layout-field-offset layout "toit::List<unsigned char>" "length_")
  if bytecodes-length <= 0 or
      not is-captured capture bytecodes-data bytecodes-length:
    throw "PROGRAM_BYTECODES_NOT_CAPTURED"
  bytecodes := capture.read bytecodes-data bytecodes-length
  bytecodes-sha := format.bytes-to-hex (crypto.sha256 bytecodes)
  program-layout := matching-program-layout
      capture
      bytecodes-length
      bytecodes-sha
  frame-marker := bytecodes-data + 1
  stack-start := raw-address + header-size
  used-start := stack-start + top * WORD-SIZE

  raw-slots := []
  used.repeat: | relative-index |
    raw-slots.add (read-uint32 capture (used-start + relative-index * WORD-SIZE))

  markers := []
  if used >= 2:
    (used - 1).repeat: | relative-index |
      if raw-slots[relative-index] != frame-marker: continue.repeat
      bcp/int := raw-slots[relative-index + 1]
      if bcp < bytecodes-data or bcp >= bytecodes-data + bytecodes-length:
        continue.repeat
      markers.add relative-index

  frames := []
  markers.size.repeat: | frame-index |
    marker-index/int := markers[frame-index]
    end := frame-index + 1 < markers.size ? markers[frame-index + 1] : used
    slots := []
    relative-index := marker-index + 2
    while relative-index < end:
      slots.add (decode-stack-slot
          capture
          used-start
          top
          relative-index
          raw-slots[relative-index]
          bytecodes-data
          bytecodes-length
          frame-marker)
      relative-index++
    bcp/int := raw-slots[marker-index + 1]
    frame := {
      "index": frame-index,
      "kind": frame-index == 0 ? "current" : "caller",
      "bytecode-pointer-kind": frame-index == 0 ? "current" : "return",
      "marker-slot-index": top + marker-index,
      "marker-address": format.hex-address
          used-start + marker-index * WORD-SIZE,
      "bytecode-slot-index": top + marker-index + 1,
      "bytecode-pointer": format.hex-address bcp,
      "absolute-bci": bcp - bytecodes-data,
      "slots": slots,
    }
    if program-layout:
      decorate-frame frame program-layout bytecodes
    frames.add frame

  classify-frame-slots frames (program-layout != null)

  unframed := []
  unframed-end := markers.is-empty ? used : markers[0]
  unframed-end.repeat: | relative-index |
    unframed.add (decode-stack-slot
        capture
        used-start
        top
        relative-index
        raw-slots[relative-index]
        bytecodes-data
        bytecodes-length
        frame-marker)

  decorate-stack-values
      capture
      raw-address
      length
      frames
      unframed
      program
      layout
      program-layout
  if program-layout:
    classify-stack-control-state frames
    decorate-current-operand-roles frames bytecodes program-layout

  base-result["state"] = "published"
  base-result["used-slots"] = used
  base-result["bytecodes"] = {
    "address": format.hex-address bytecodes-data,
    "length": bytecodes-length,
    "sha256": bytecodes-sha,
    "frame-marker": hex-word frame-marker,
  }
  if program-layout:
    base-result["program-layout"] = {
      "source-snapshot-attachment-id":
          program-layout["source-snapshot-attachment-id"],
      "source-snapshot-sha256": program-layout["source-snapshot-sha256"],
      "snapshot-uuid": program-layout.get "snapshot-uuid",
      "sdk-version": program-layout.get "sdk-version",
      "method-count": program-layout["methods"].size,
    }
  else:
    layouts/List := capture.metadata.get "program-layouts" --if-absent=: []
    base-result["diagnostics"] = [
      layouts.is-empty
          ? "PROGRAM_LAYOUT_NOT_AVAILABLE"
          : "PROGRAM_BYTECODES_UNMATCHED",
    ]
  base-result["frame-count"] = frames.size
  base-result["frames"] = frames
  base-result["unframed-slots"] = unframed
  local-names-available := false
  frames.do: | frame/Map |
    method := frame.get "method"
    if method and method.get "variable-metadata-available":
      local-names-available = true
  base-result["local-names-available"] = local-names-available
  return base-result

decorate-stack-values
    capture/toit-model.View stack-address/int length/int frames/List unframed/List
    program/int layout/Map program-layout/Map?
    -> none:
  slots := []
  unframed.do: slots.add it
  frames.do: | frame/Map |
    frame-slots/List := frame["slots"]
    frame-slots.do: slots.add it
  slots.do: | slot/Map |
    decorate-runtime-value capture slot program layout program-layout
  if not program-layout: return

  by-index := {:}
  slots.do: | slot/Map | by-index[slot["stack-index"]] = slot
  slots.do: | slot/Map |
    if (slot.get "candidate-kind") != "smi": continue.do
    encoded-value := slot.get "value"
    if not encoded-value is int: continue.do
    distance := encoded-value - BLOCK-SALT
    if distance <= 0 or distance > length: continue.do
    target-index := length - distance
    target/Map? := by-index.get target-index
    if not target or (target.get "candidate-kind") != "smi": continue.do
    header-bci := target.get "value"
    if not header-bci is int: continue.do
    method := toit-model.method-at-header-bci program-layout header-bci
    if not method or (method.get "kind") != "block": continue.do

    method-summary := {
      "name": method["name"],
      "kind": method["kind"],
      "header-bci": method["header-bci"],
      "entry-bci": method["entry-bci"],
      "end-bci": method["end-bci"],
    }
    positions/List := method.get "positions" --if-absent=: []
    if not positions.is-empty:
      position/Map := positions[0]
      method-summary["source"] = {
        "path": method.get "path",
        "line": position.get "line",
        "column": position.get "column",
      }
    block := {
      "stack": format.hex-address stack-address,
      "stack-index": target-index,
      "slot-address": target["address"],
      "owner-frame-index": target.get "owner-frame-index",
      "method": method-summary,
    }
    slot["encoded-candidate-kind"] = "smi"
    slot["candidate-kind"] = "block-reference"
    slot["block"] = block
    slot["display"] =
        "block $(method["name"]) -> $(format.hex-address stack-address)[$target-index]"

/**
Separates stack-block anchors and the fixed four-slot unwind-link record from
  source-level operand-stack values.

The compiler emits a block method-id, four `LINK` fields, and a stack-relative
  reference to that method-id immediately before invoking a protected block.
The reference-to-anchor distance is therefore structural evidence even after
  an exception or non-local return has replaced the sentinel field values.
*/
classify-stack-control-state frames/List -> none:
  slots := []
  frames.do: | frame/Map |
    physical-slots/List := frame.get "slots" --if-absent=: []
    physical-slots.do: slots.add it
  by-index := {:}
  slots.do: | slot/Map | by-index[slot["stack-index"]] = slot

  slots.do: | reference/Map |
    block := reference.get "block"
    if not block: continue.do
    anchor-index := block.get "stack-index"
    if not anchor-index is int: continue.do
    anchor/Map? := by-index.get anchor-index
    if not anchor: continue.do
    method := block.get "method"
    anchor["anchored-block"] = {
      "method": method,
      "referenced-by-stack-index": reference["stack-index"],
      "referenced-by-owner-frame-index": reference.get "owner-frame-index",
    }
    anchor-role := anchor.get "role"
    if not anchor-role or
        anchor-role == "operand" or
        anchor-role == "local-or-operand":
      anchor["storage-role"] = anchor-role
      anchor["role"] = "block-anchor"
      anchor["role-confidence"] = "resolved-stack-block-reference"
      if method:
        anchor["name"] = method["name"]
        anchor["display"] = "stack block $(method["name"])"
      anchor["encoded-candidate-kind"] = anchor.get "candidate-kind"
      anchor["candidate-kind"] = "block-anchor"

    reference-index/int := reference["stack-index"]
    if anchor-index - reference-index != 5: continue.do
    physical-frame := reference.get "physical-frame-index"
    if physical-frame == null:
      physical-frame = reference.get "owner-frame-index"
    if physical-frame == null: continue.do
    link-slots := []
    link-valid := true
    4.repeat: | offset |
      link-slot/Map? := by-index.get (reference-index + offset + 1)
      if not link-slot:
        link-valid = false
        continue.repeat
      link-physical-frame := link-slot.get "physical-frame-index"
      if link-physical-frame == null:
        link-physical-frame = link-slot.get "owner-frame-index"
      if link-physical-frame != physical-frame:
        link-valid = false
      link-slots.add link-slot
    if not link-valid: continue.do

    control-roles := [
      ["unwind-chain", "unwind chain"],
      ["unwind-reason", "unwind reason"],
      ["unwind-target", "unwind target"],
      ["unwind-result", "unwind result or exception"],
    ]
    link-slots.size.repeat: | index |
      link-slot/Map := link-slots[index]
      previous-role := link-slot.get "role"
      link-slot["storage-role"] = previous-role
      link-slot["role"] = "vm-control"
      link-slot["control-role"] = control-roles[index][0]
      link-slot["name"] = control-roles[index][1]
      link-slot["role-confidence"] = "stack-block+link-record-layout"
      link-slot["linked-block"] = {
        "anchor-stack-index": anchor-index,
        "method": method,
      }

  frames.do: | frame/Map |
    locals/List := frame.get "local-slots" --if-absent=: []
    frame["local-slots"] = locals.filter: | slot/Map |
      (slot.get "role") == "local"
    operands/List := frame.get "operand-slots" --if-absent=: []
    frame["operand-slots"] = operands.filter: | slot/Map |
      (slot.get "role") == "operand"
    unclassified/List :=
        frame.get "local-or-operand-slots" --if-absent=: []
    frame["local-or-operand-slots"] = unclassified.filter: | slot/Map |
      (slot.get "role") == "local-or-operand"
    control-slots := []
    block-anchors := []
    physical-slots/List := frame.get "slots" --if-absent=: []
    physical-slots.do: | slot/Map |
      if (slot.get "owner-frame-index") != frame["index"]: continue.do
      if (slot.get "role") == "vm-control": control-slots.add slot
      if (slot.get "role") == "block-anchor": block-anchors.add slot
    frame["vm-control-slots"] = control-slots
    frame["block-anchor-slots"] = block-anchors

matching-program-layout
    capture/toit-model.View bytecodes-length/int bytecodes-sha/string
    -> Map?:
  layouts/List := capture.metadata.get "program-layouts" --if-absent=: []
  layouts.do: | layout/Map |
    if layout["bytecodes-length"] == bytecodes-length and
        layout["bytecodes-sha256"] == bytecodes-sha:
      return layout
  return null

decorate-frame frame/Map layout/Map bytecodes/ByteArray -> none:
  absolute-bci/int := frame["absolute-bci"]
  method := toit-model.method-at-bci layout absolute-bci
  if not method:
    frame["symbolization-diagnostic"] = "METHOD_NOT_FOUND"
    return
  relative-bci := absolute-bci - method["entry-bci"]
  method-result := {
    "name": method["name"],
    "kind": method["kind"],
    "header-bci": method["header-bci"],
    "entry-bci": method["entry-bci"],
    "end-bci": method["end-bci"],
    "relative-bci": relative-bci,
    "arity": method["arity"],
    "max-height": method["max-height"],
  }
  if method.contains "parameters" and method.contains "locals":
    method-result["parameters"] = method["parameters"]
    method-result["locals"] = method["locals"]
    method-result["variable-metadata-available"] = true
  position := value-at-or-before method["positions"] relative-bci
  if position:
    method-result["source"] = {
      "path": method["path"],
      "line": position["line"],
      "column": position["column"],
    }
  instruction := instruction-at-or-before
      method
      layout["opcodes"]
      bytecodes
      relative-bci
  if instruction:
    opcode/int := instruction["opcode"]
    opcodes/List := layout["opcodes"]
    if opcode >= 0 and opcode < opcodes.size:
      opcode-info/Map := opcodes[opcode]
      instruction-result := {
        "relative-bci": instruction["relative-bci"],
        "absolute-bci": method["entry-bci"] + instruction["relative-bci"],
        "opcode": opcode,
        "name": opcode-info["name"],
        "size": opcode-info["size"],
        "description": opcode-info["description"],
      }
      instruction-result["pointer-position"] =
          instruction["relative-bci"] == relative-bci ? "at-instruction" : "inside-instruction"
      method-result["instruction"] = instruction-result
  frame["method"] = method-result
  frame["non-argument-live-value-limit"] = method["max-height"]
  frame["slot-role-note"] =
      method-result.get "variable-metadata-available"
          ? "Snapshot frame-debug metadata identifies parameters and source-local stack-slot lifetimes. Resolved stack blocks and VM control records are separated; remaining live values are operand-stack temporaries."
          : "Method arity separates arguments from the caller's live values. This snapshot does not serialize local names or bytecode liveness, so remaining values stay local/operand candidates."

classify-frame-slots frames/List has-program-layout/bool -> none:
  if not has-program-layout:
    frames.do: | frame/Map |
      slots/List := frame["slots"]
      slots.do: | slot/Map |
        slot["role"] = "live-frame-value"
        slot["role-candidates"] = ["argument", "local", "operand"]
        slot["role-confidence"] = "unclassified"
      frame["argument-slots"] = []
      frame["local-or-operand-slots"] = slots
      frame["live-value-count"] = slots.size
    return

  frames.size.repeat: | frame-index |
    frame/Map := frames[frame-index]
    segment/List := frame["slots"]
    callee-arity := 0
    if frame-index > 0:
      previous/Map := frames[frame-index - 1]
      previous-method := previous.get "method"
      if previous-method: callee-arity = previous-method["arity"]
    owned-start := min callee-arity segment.size
    if callee-arity > segment.size:
      frame["slot-classification-diagnostic"] =
          "CALLEE_ARGUMENTS_EXCEED_SEGMENT"
    owned := segment[owned-start..]
    owned.do: | slot/Map |
      slot["role"] = "local-or-operand"
      slot["role-candidates"] = ["local", "operand"]
      slot["role-confidence"] = "frame-marker+method-arity"
      slot["owner-frame-index"] = frame-index
      slot["physical-frame-index"] = frame-index
      slot["physical-storage"] = "frame-segment"
    owned-start.repeat: | argument-index |
      slot/Map := segment[argument-index]
      slot["role"] = "callee-argument"
      slot["argument-stack-index"] = argument-index
      slot["role-confidence"] = "frame-marker+method-arity"
      slot["owner-frame-index"] = frame-index - 1
      slot["physical-frame-index"] = frame-index
      slot["physical-storage"] = "caller-frame-segment"
    frame["local-or-operand-slots"] = owned

  frames.size.repeat: | frame-index |
    frame/Map := frames[frame-index]
    method := frame.get "method"
    arity := method ? method["arity"] : 0
    arguments := []
    if frame-index + 1 < frames.size:
      next-segment/List := frames[frame-index + 1]["slots"]
      available := min arity next-segment.size
      if available > 0: arguments = next-segment[..available]
      if available < arity:
        frame["argument-diagnostic"] = "ARGUMENT_SLOTS_NOT_AVAILABLE"
    else if arity > 0:
      frame["argument-diagnostic"] = "ARGUMENT_SLOTS_NOT_AVAILABLE"
    frame["argument-slots"] = arguments
    frame["live-value-count"] =
        frame["local-or-operand-slots"].size + arguments.size

    arguments.do: | slot/Map |
      slot["storage-role"] = slot["role"]
      slot["role"] = "parameter"
      slot["parameter-index"] = slot["argument-stack-index"]
      slot["role-confidence"] = "frame-marker+method-arity"

    if not method or not method.get "variable-metadata-available": continue.repeat
    parameters/List := method["parameters"]
    arguments.do: | slot/Map |
      parameter-index/int := slot["argument-stack-index"]
      parameter := variable-for-index parameters parameter-index "index"
      slot["role-confidence"] = "snapshot-frame-debug"
      if parameter:
        slot["name"] = parameter["name"]
        slot["parameter-kind"] = parameter["kind"]
        add-variable-source slot parameter method["source"]

    relative-bci/int := method["relative-bci"]
    locals/List := method["locals"]
    active-locals := []
    locals.do: | local/Map |
      if local["start-bci"] <= relative-bci and
          relative-bci < local["end-bci"]:
        active-locals.add local
    local-slots := []
    operand-slots := []
    owned/List := frame["local-or-operand-slots"]
    owned.size.repeat: | physical-index |
      stack-height := owned.size - physical-index - 1
      slot/Map := owned[physical-index]
      local := variable-for-index active-locals stack-height "stack-height"
      if local:
        slot["role"] = "local"
        slot["name"] = local["name"]
        slot["local-stack-height"] = stack-height
        slot["role-confidence"] = "snapshot-frame-debug"
        add-variable-source slot local method["source"]
        local-slots.add slot
      else:
        slot["role"] = "operand"
        slot["operand-stack-index"] = stack-height
        slot["role-confidence"] = "snapshot-frame-debug"
        operand-slots.add slot
    frame["local-slots"] = local-slots
    frame["operand-slots"] = operand-slots
    frame["local-or-operand-slots"] = []

/**
Labels operand-stack values only when the stopped current bytecode determines
their role.  Caller frames point at return addresses and are deliberately not
interpreted as if their bytecode were currently executing.
*/
decorate-current-operand-roles
    frames/List bytecodes/ByteArray program-layout/Map
    -> none:
  if frames.is-empty: return
  frame/Map := frames[0]
  method := frame.get "method"
  if not method: return
  instruction := method.get "instruction"
  if not instruction or
      (instruction.get "pointer-position") != "at-instruction":
    return
  operands/List := frame.get "operand-slots" --if-absent=: []
  name/string := instruction["name"]

  if name == "POP_1":
    label-operand-tail operands ["discarded value"] name
    return
  if name == "RETURN":
    label-operand-tail operands ["return value"] name
    return
  if name == "THROW":
    label-operand-tail operands ["exception"] name
    return
  if name.starts-with "IS_" or name.starts-with "AS_":
    label-operand-tail operands ["checked value"] name
    return

  if name == "BRANCH_IF_TRUE" or
      name == "BRANCH_IF_FALSE" or
      name == "BRANCH_IF_NOT_NULL" or
      name == "BRANCH_BACK_IF_TRUE" or
      name == "BRANCH_BACK_IF_FALSE" or
      name == "BRANCH_BACK_IF_NOT_NULL":
    label-operand-tail operands ["condition"] name
    return

  binary-operation := binary-operation-for-bytecode name
  if binary-operation:
    label-operand-tail operands ["left operand", "right operand"] name
    frame["pending-expression"] = {
      "kind": "binary-operation",
      "operation": binary-operation,
    }
    return

  if name == "INVOKE_AT":
    label-operand-tail operands ["receiver", "index"] name
    return
  if name == "INVOKE_AT_PUT":
    label-operand-tail operands ["receiver", "index", "value"] name
    return
  if name == "INVOKE_SIZE" or name == "INVOKE_VIRTUAL_GET":
    label-operand-tail operands ["receiver"] name
    return
  if name == "INVOKE_VIRTUAL_SET":
    label-operand-tail operands ["receiver", "value"] name
    return

  absolute-bci/int := instruction["absolute-bci"]
  arity := 0
  call-kind/string? := null
  target/Map? := null
  if name == "INVOKE_STATIC" or name == "INVOKE_STATIC_TAIL":
    if absolute-bci + 2 >= bytecodes.size: return
    dispatch-index := bytecodes[absolute-bci + 1] |
        (bytecodes[absolute-bci + 2] << 8)
    dispatch-table/List := program-layout.get "dispatch-table" --if-absent=: []
    if dispatch-index >= dispatch-table.size: return
    target = toit-model.method-at-header-bci
        program-layout
        dispatch-table[dispatch-index]
    if not target: return
    arity = target["arity"]
    call-kind = "static"
  else if name == "INVOKE_BLOCK":
    if absolute-bci + 1 >= bytecodes.size: return
    arity = bytecodes[absolute-bci + 1]
    call-kind = "block"
  else if name == "INVOKE_VIRTUAL":
    if absolute-bci + 1 >= bytecodes.size: return
    arity = bytecodes[absolute-bci + 1] + 1
    call-kind = "virtual"
  else if name == "INVOKE_VIRTUAL_WIDE":
    if absolute-bci + 2 >= bytecodes.size: return
    arity = bytecodes[absolute-bci + 1] |
        (bytecodes[absolute-bci + 2] << 8)
    arity++
    call-kind = "virtual"
  else:
    return
  if arity <= 0 or operands.size < arity: return

  call-slots/List := operands[operands.size - arity..]
  if call-kind == "block" and not call-slots.is-empty:
    block := call-slots[0].get "block"
    if block:
      block-method := block.get "method"
      if block-method:
        header-bci := block-method.get "header-bci"
        if header-bci is int:
          target = toit-model.method-at-header-bci program-layout header-bci
  parameters/List := target
      ? target.get "parameters" --if-absent=: []
      : []
  call-slots.size.repeat: | index |
    slot/Map := call-slots[index]
    parameter := variable-for-index parameters index "index"
    bytecode-role := "call-argument"
    if target: bytecode-role = "pending-parameter"
    else if index == 0: bytecode-role = "call-receiver"
    slot["bytecode-role"] = bytecode-role
    slot["pending-parameter-index"] = index
    slot["bytecode-role-confidence"] = target
        ? "current-bytecode+static-target"
        : "current-bytecode-stack-effect"
    if parameter:
      slot["pending-parameter-name"] = parameter["name"]
      slot["pending-parameter-kind"] = parameter["kind"]
      add-variable-source slot parameter {"path": target.get "path"}
    else if index == 0 and call-kind != "static":
      slot["pending-parameter-name"] = "receiver"
    else:
      slot["pending-parameter-name"] = "argument $index"
  pending-call := {
    "kind": call-kind,
    "arity": arity,
    "instruction": name,
  }
  if target:
    pending-call["target"] = {
      "name": target["name"],
      "kind": target["kind"],
      "header-bci": target["header-bci"],
    }
  frame["pending-call"] = pending-call

label-operand-tail operands/List labels/List instruction/string -> none:
  if operands.size < labels.size: return
  selected/List := operands[operands.size - labels.size..]
  selected.size.repeat: | index |
    slot/Map := selected[index]
    label/string := labels[index]
    slot["bytecode-role"] = label.replace --all " " "-"
    slot["bytecode-role-name"] = label
    slot["bytecode-role-confidence"] = "current-bytecode-stack-effect"
    slot["bytecode-instruction"] = instruction

binary-operation-for-bytecode name/string -> string?:
  operations := {
    "INVOKE_EQ": "==",
    "INVOKE_LT": "<",
    "INVOKE_GT": ">",
    "INVOKE_LTE": "<=",
    "INVOKE_GTE": ">=",
    "INVOKE_BIT_OR": "|",
    "INVOKE_BIT_XOR": "^",
    "INVOKE_BIT_AND": "&",
    "INVOKE_BIT_SHL": "<<",
    "INVOKE_BIT_SHR": ">>",
    "INVOKE_BIT_USHR": ">>>",
    "INVOKE_ADD": "+",
    "INVOKE_SUB": "-",
    "INVOKE_MUL": "*",
    "INVOKE_DIV": "/",
    "INVOKE_MOD": "%",
    "IDENTICAL": "identical",
  }
  return operations.get name

variable-for-index variables/List index/int field/string -> Map?:
  variables.do: | variable/Map |
    if variable[field] == index: return variable
  return null

add-variable-source slot/Map variable/Map method-source/Map? -> none:
  line := variable.get "line"
  column := variable.get "column"
  if not line: return
  slot["declaration"] = {
    "path": method-source ? method-source["path"] : null,
    "line": line,
    "column": column,
  }

value-at-or-before entries/List relative-bci/int -> Map?:
  candidate/Map? := null
  entries.do: | entry/Map |
    if entry["relative-bci"] > relative-bci: return candidate
    candidate = entry
  return candidate

instruction-at-or-before
    method/Map opcodes/List bytecodes/ByteArray relative-bci/int
    -> Map?:
  method-entry/int := method["entry-bci"]
  method-size/int := method["bytecode-size"]
  instruction-bci := 0
  candidate/Map? := null
  while instruction-bci < method-size:
    if instruction-bci > relative-bci: return candidate
    opcode := bytecodes[method-entry + instruction-bci]
    if opcode < 0 or opcode >= opcodes.size: return null
    opcode-info/Map := opcodes[opcode]
    size/int := opcode-info["size"]
    if size <= 0 or instruction-bci + size > method-size: return null
    candidate = {
      "relative-bci": instruction-bci,
      "opcode": opcode,
    }
    instruction-bci += size
  return candidate

decode-stack-slot
    capture/toit-model.View used-start/int top/int relative-index/int raw/int
    bytecodes-data/int bytecodes-length/int frame-marker/int
    -> Map:
  address := used-start + relative-index * WORD-SIZE
  result := {
    "stack-index": top + relative-index,
    "address": format.hex-address address,
    "raw": hex-word raw,
    "evidence": "captured-memory",
  }
  if raw == frame-marker:
    result["candidate-kind"] = "frame-marker"
  else if raw >= bytecodes-data and raw < bytecodes-data + bytecodes-length:
    result["candidate-kind"] = "bytecode-pointer"
    result["absolute-bci"] = raw - bytecodes-data
  else:
    value := decode-word capture address
    value.do: | key/any item/any |
      result[key] = item
  return result

search-bytes
    capture/toit-model.View needle/ByteArray limit/int=100
    -> Map:
  if needle.is-empty or needle.size > MAX-SEARCH-PATTERN:
    throw "INVALID_SEARCH_PATTERN"
  if limit <= 0 or limit > MAX-SEARCH-RESULTS: throw "INVALID_LIMIT"
  matches := []
  truncated := false
  capture.regions.do: | region/target.MemoryRegion |
    if truncated: continue.do
    offset := 0
    carry := #[]
    while offset < region.size and not truncated:
      read-size := min SEARCH-READ-CHUNK (region.size - offset)
      bytes := capture.read (region.address + offset) read-size
      window := carry + bytes
      window-start := offset - carry.size
      local := 0
      while local + needle.size <= window.size:
        absolute-offset := window-start + local
        already-scanned := absolute-offset + needle.size <= offset
        if not already-scanned and matches-at window local needle:
          matches.add {
            "address": format.hex-address (region.address + absolute-offset),
            "region-id": region.id,
          }
          if matches.size == limit:
            truncated = true
            break
        local++
      carry-size := min (needle.size - 1) window.size
      carry = carry-size == 0 ? #[] : window[window.size - carry-size..]
      offset += read-size
  return {
    "matches": matches,
    "limit": limit,
    "truncated": truncated,
  }

decode-runtime capture/toit-model.View layout/Map -> Map:
  ensure-supported-layout capture
  validate-runtime-layout layout
  diagnostics := []
  runtime-state := gc-state.describe capture.observation
  vm-slot := layout-symbol-address layout "toit::VM::current_"
  roots := {"vm-slot": format.hex-address vm-slot}
  result := {
    "layout-format": layout["format"],
    "layout-format-version": layout["format-version"],
    "roots": roots,
    "process-groups": [],
    "diagnostics": diagnostics,
    "runtime-state": runtime-state,
    "semantic-coherence": capture.metadata["completeness"].get
        "semantic-coherence"
        --if-absent=: false,
  }
  vm := read-pointer-if-captured capture vm-slot diagnostics "vm-current"
  if not vm: return result
  roots["vm"] = format.hex-address vm
  scheduler-offset := layout-field-offset layout "toit::VM" "scheduler_"
  scheduler := read-pointer-if-captured
      capture
      (vm + scheduler-offset)
      diagnostics
      "scheduler"
  if not scheduler: return result
  roots["scheduler"] = format.hex-address scheduler
  result["scheduler"] = decode-scheduler capture scheduler layout diagnostics
  result["process-groups"] = decode-process-groups
      capture
      scheduler
      layout
      diagnostics
  return result

decode-process-stacks capture/toit-model.View layout/Map -> Map:
  return decode-process-stacks-from-runtime
      capture
      (decode-runtime capture layout)
      layout

decode-process-stacks-from-runtime
    capture/toit-model.View decoded-runtime/Map layout/Map
    -> Map:
  items := []
  process-count := 0
  decoded-count := 0
  global-count := 0
  complete-global-table-count := 0
  groups/List := decoded-runtime.get "process-groups" --if-absent=: []
  groups.do: | group/Map |
    processes/List := group.get "processes" --if-absent=: []
    processes.do: | process/Map |
      process-count++
      diagnostics := []
      item := {
        "process-group": {
          "id": group.get "id",
          "address": group.get "address",
          "program": group.get "program",
          "container": group.get "container",
        },
        "process": {
          "id": process.get "id",
          "address": process.get "address",
          "state": process.get "state",
          "priority": process.get "priority",
        },
        "status": "unavailable",
        "diagnostics": diagnostics,
      }
      items.add item

      object-heap/Map? := process.get "object-heap"
      if not object-heap:
        add-process-stack-diagnostic
            diagnostics
            "OBJECT_HEAP_NOT_DISCOVERED"
            "The process has no decoded object heap."
        continue.do
      item["object-heap"] = object-heap.get "address"

      program-value := object-heap.get "program"
      if not program-value: program-value = group.get "program"
      if not program-value:
        add-process-stack-diagnostic
            diagnostics
            "PROGRAM_NOT_DISCOVERED"
            "Neither the process object heap nor its group has a program pointer."
        continue.do
      item["program"] = program-value
      globals := object-heap.get "globals"
      item["globals"] = globals or decode-process-globals
          capture
          (format.parse-address object-heap["address"])
          (format.parse-address program-value)
          layout
      item-globals/Map := item["globals"]
      total-globals := item-globals.get "total"
      if total-globals is int: global-count += total-globals
      if item-globals.get "complete": complete-global-table-count++

      task/Map? := object-heap.get "task"
      if not task:
        add-process-stack-diagnostic
            diagnostics
            "TASK_NOT_DECODED"
            "The object heap's task was not captured or could not be decoded."
        continue.do
      task-id/Map? := task.get "task-id"
      item["task"] = {
        "address": task.get "address",
        "tagged-reference": object-heap.get "task-reference",
        "id": task-id ? task-id.get "value" : null,
      }

      stack-word/Map? := task.get "stack"
      stack-address-value := stack-word ? stack-word.get "object-address" : null
      if not stack-address-value:
        add-process-stack-diagnostic
            diagnostics
            "STACK_NOT_DISCOVERED"
            "The task has no captured heap-stack reference."
        continue.do
      item["stack-address"] = stack-address-value

      stack/Map? := null
      exception := catch:
        stack = decode-stack
            capture
            (format.parse-address stack-address-value)
            (format.parse-address program-value)
            layout
      if exception:
        item["status"] = "error"
        add-process-stack-diagnostic diagnostics "STACK_DECODE_FAILED" "$exception"
        continue.do
      item["status"] = "decoded"
      item["stack"] = stack
      decoded-count++

  return {
    "items": items,
    "process-count": process-count,
    "decoded-stack-count": decoded-count,
    "global-count": global-count,
    "complete": decoded-count == process-count,
    "globals-complete": complete-global-table-count == process-count,
    "variables-complete": decoded-count == process-count and
        complete-global-table-count == process-count,
    "runtime-diagnostics":
        decoded-runtime.get "diagnostics" --if-absent=: [],
    "semantic-coherence": decoded-runtime.get "semantic-coherence",
    "runtime-state": decoded-runtime.get "runtime-state",
  }

add-process-stack-diagnostic
    diagnostics/List code/string context/string
    -> none:
  diagnostics.add {
    "code": code,
    "context": context,
  }

decode-scheduler
    capture/toit-model.View scheduler/int layout/Map diagnostics/List
    -> Map:
  result := {"address": format.hex-address scheduler}
  [
    ["num-processes", "num_processes_"],
    ["num-threads", "num_threads_"],
    ["max-threads", "max_threads_"],
    ["gc-waiting-for-preemption", "gc_waiting_for_preemption_"],
  ].do: | names/List |
    offset := layout-field-offset layout "toit::Scheduler" names[1]
    value := read-uint32-if-captured
        capture
        (scheduler + offset)
        diagnostics
        names[0]
    result[names[0]] = value
  gc-offset := layout-field-offset layout "toit::Scheduler" "gc_cross_processes_"
  result["cross-process-gc"] = read-byte-if-captured
      capture
      (scheduler + gc-offset)
      diagnostics
      "cross-process-gc"
  return result

decode-process-groups
    capture/toit-model.View scheduler/int layout/Map diagnostics/List
    -> List:
  groups := []
  groups-offset := layout-field-offset layout "toit::Scheduler" "groups_"
  next-offset := layout-field-offset
      layout
      "DoubleLinkedListElement<toit::ProcessGroup, 1>"
      "next_"
  anchor := scheduler + groups-offset
  next := read-pointer-if-captured capture (anchor + next-offset) diagnostics "groups-next"
  seen := {}
  while next and next != anchor and groups.size < MAX-RUNTIME-LIST:
    if seen.contains next:
      add-runtime-diagnostic diagnostics "GROUP_LIST_CYCLE" next "process-groups"
      break
    seen.add next
    groups.add (decode-process-group capture next layout diagnostics)
    next = read-pointer-if-captured
        capture
        (next + next-offset)
        diagnostics
        "group-next"
  if groups.size == MAX-RUNTIME-LIST:
    add-runtime-diagnostic diagnostics "GROUP_LIST_LIMIT" anchor "process-groups"
  return groups

decode-process-group
    capture/toit-model.View address/int layout/Map diagnostics/List
    -> Map:
  id-offset := layout-field-offset layout "toit::ProcessGroup" "id_"
  program-offset := layout-field-offset layout "toit::ProcessGroup" "program_"
  processes-offset := layout-field-offset layout "toit::ProcessGroup" "processes_"
  program := read-pointer-if-captured
      capture
      (address + program-offset)
      diagnostics
      "process-group-program"
  result := {
    "address": format.hex-address address,
    "id": read-int32-if-captured
        capture
        (address + id-offset)
        diagnostics
        "process-group-id",
    "program": pointer-address program,
  }
  if program:
    program-layout := program-layout-for-program capture program layout
    container := program-container-identity program-layout
    if container: result["container"] = container
  scope/Map? := capture.metadata.get "capture-scope"
  if scope and (scope.get "kind") == "process-group":
    selected/Map := scope["selected"]
    if result["id"] != selected["id"]:
      result["capture-state"] = "omitted"
      result["processes"] = []
      return result
    result["capture-state"] = "selected"
  result["processes"] = decode-processes
      capture
      (address + processes-offset)
      layout
      diagnostics
  return result

program-container-identity program-layout/Map? -> Map?:
  if not program-layout: return null
  result := {
    "snapshot-attachment-id":
        program-layout.get "source-snapshot-attachment-id",
    "snapshot-name": program-layout.get "source-snapshot-name",
  }
  container-name := program-layout.get "source-container-name"
  if container-name: result["name"] = container-name
  return result

decode-processes
    capture/toit-model.View anchor/int layout/Map diagnostics/List
    -> List:
  processes := []
  next-offset := layout-field-offset
      layout
      "LinkedListElement<toit::Process, 1>"
      "next_"
  next := read-pointer-if-captured capture (anchor + next-offset) diagnostics "processes-next"
  seen := {}
  while next and processes.size < MAX-RUNTIME-LIST:
    if seen.contains next:
      add-runtime-diagnostic diagnostics "PROCESS_LIST_CYCLE" next "processes"
      break
    seen.add next
    processes.add (decode-process capture next layout diagnostics)
    next = read-pointer-if-captured
        capture
        (next + next-offset)
        diagnostics
        "process-next"
  if processes.size == MAX-RUNTIME-LIST:
    add-runtime-diagnostic diagnostics "PROCESS_LIST_LIMIT" anchor "processes"
  return processes

decode-process
    capture/toit-model.View address/int layout/Map diagnostics/List
    -> Map:
  id := read-int32-if-captured
      capture
      (address + (layout-field-offset layout "toit::Process" "id_"))
      diagnostics
      "process-id"
  state := read-uint32-if-captured
      capture
      (address + (layout-field-offset layout "toit::Process" "state_"))
      diagnostics
      "process-state"
  result := {
    "address": format.hex-address address,
    "id": id,
    "state-value": state,
    "state": state != null and state >= 0 and state < PROCESS-STATES.size
        ? PROCESS-STATES[state]
        : "unknown",
    "priority": read-byte-if-captured
        capture
        (address + (layout-field-offset layout "toit::Process" "priority_"))
        diagnostics
        "process-priority",
  }
  heap-address := address + (layout-field-offset layout "toit::Process" "object_heap_")
  result["object-heap"] = decode-object-heap capture heap-address layout diagnostics
  result["program-heap"] = {
    "address": pointer-address
        read-pointer-if-captured
            capture
            (address + (layout-field-offset layout "toit::Process" "program_heap_address_"))
            diagnostics
            "program-heap-address",
    "size": read-uint32-if-captured
        capture
        (address + (layout-field-offset layout "toit::Process" "program_heap_size_"))
        diagnostics
        "program-heap-size",
  }
  return result

decode-object-heap
    capture/toit-model.View address/int layout/Map diagnostics/List
    -> Map:
  program := read-pointer-if-captured
      capture
      (address + (layout-field-offset layout "toit::ObjectHeap" "program_"))
      diagnostics
      "object-heap-program"
  result := {
    "address": format.hex-address address,
    "program": pointer-address program,
  }
  task := read-pointer-if-captured
      capture
      (address + (layout-field-offset layout "toit::ObjectHeap" "task_"))
      diagnostics
      "task"
  result["task-reference"] = pointer-address task
  if task:
    task-evidence/Map? := null
    exception := catch:
      task-evidence = program
          ? decode-object-with-program capture task program layout
          : decode-object capture task
    if exception:
      add-runtime-diagnostic diagnostics "TASK_DECODE_FAILED" task "$exception"
    else:
      result["task"] = task-evidence
  if program:
    result["globals"] = decode-process-globals capture address program layout
  result["gc-count"] = read-uint32-if-captured
      capture
      (address + (layout-field-offset layout "toit::ObjectHeap" "gc_count_"))
      diagnostics
      "gc-count"
  result["full-gc-count"] = read-uint32-if-captured
      capture
      (address + (layout-field-offset layout "toit::ObjectHeap" "full_gc_count_"))
      diagnostics
      "full-gc-count"
  two-space := address + (layout-field-offset layout "toit::ObjectHeap" "two_space_heap_")
  old-space := two-space + (layout-field-offset layout "toit::TwoSpaceHeap" "old_space_")
  new-space := two-space + (layout-field-offset layout "toit::TwoSpaceHeap" "semi_space_")
  result["old-space"] = decode-space
      capture
      old-space
      layout
      diagnostics
      --old
      --program=program
  result["new-space"] = decode-space
      capture
      new-space
      layout
      diagnostics
      --no-old
      --program=program
  return result

decode-space
    capture/toit-model.View address/int layout/Map diagnostics/List
    --old/bool --program/int?=null
    -> Map:
  result := {
    "address": format.hex-address address,
    "kind": old ? "old-space" : "new-space",
    "top": pointer-address
        read-pointer-if-captured
            capture
            (address + (layout-field-offset layout "toit::Space" "top_"))
            diagnostics
            "space-top",
    "limit": pointer-address
        read-pointer-if-captured
            capture
            (address + (layout-field-offset layout "toit::Space" "limit_"))
            diagnostics
            "space-limit",
  }
  runtime-state := gc-state.describe capture.observation
  result["gc-view"] = gc-state.space-view runtime-state result["kind"]
  if old:
    result["tracking-allocations"] = read-byte-if-captured
        capture
        (address + (layout-field-offset layout "toit::OldSpace" "tracking_allocations_"))
        diagnostics
        "old-space-tracking-allocations"
    result["compacting-policy"] = read-byte-if-captured
        capture
        (address + (layout-field-offset layout "toit::OldSpace" "compacting_"))
        diagnostics
        "old-space-compacting-policy"
    result["used"] = read-uint32-if-captured
        capture
        (address + (layout-field-offset layout "toit::OldSpace" "used_"))
        diagnostics
        "old-space-used"
    result["promoted-track"] = pointer-address
        read-pointer-if-captured
            capture
            (address + (layout-field-offset layout "toit::OldSpace" "promoted_track_"))
            diagnostics
            "old-space-promoted-track"
  chunks := decode-chunks capture address layout diagnostics
  result["chunks"] = chunks
  if program:
    chunks.do: | chunk/Map |
      start := chunk.get "start"
      end := chunk.get "end"
      if not start or not end: continue.do
      exception := catch:
        chunk["census"] = heap-range-census
            capture
            format.parse-address start
            format.parse-address end
            program
            layout
            0
            0
            --space-kind=result["kind"]
      if exception:
        chunk["census"] = {
          "complete": false,
          "diagnostics": [{
            "code": "HEAP_CENSUS_FAILED",
            "address": start,
            "context": "$exception",
          }],
        }
    result["census"] = aggregate-space-census chunks
  return result

aggregate-space-census chunks/List -> Map:
  result := {
    "chunk-count": chunks.size,
    "censused-chunks": 0,
    "complete-chunks": 0,
    "authoritative-chunks": 0,
    "range-bytes": 0,
    "object-count": 0,
    "object-bytes": 0,
    "free-bytes": 0,
    "occupied-bytes": 0,
    "sentinel-bytes": 0,
    "unused-after-sentinel-bytes": 0,
    "external-payload-bytes": 0,
    "captured-external-payload-bytes": 0,
    "external-payload-count": 0,
    "external-payload-reference-count": 0,
  }
  type-counters := {:}
  class-counters := {:}
  liveness-counters := {:}
  phase-diagnostics := []
  runtime-state/Map? := null
  chunks.do: | chunk/Map |
    census/Map? := chunk.get "census"
    if not census: continue.do
    result["censused-chunks"] += 1
    complete := census.get "complete" --if-absent=: false
    if complete:
      result["complete-chunks"] += 1
    if census.get "authoritative":
      result["authoritative-chunks"] += 1
    if not runtime-state: runtime-state = census.get "runtime-state"
    phase-diagnostics.add-all
        census.get "phase-diagnostics" --if-absent=: []
    [
      "range-bytes",
      "object-count",
      "object-bytes",
      "free-bytes",
      "occupied-bytes",
      "sentinel-bytes",
      "unused-after-sentinel-bytes",
      "external-payload-bytes",
      "captured-external-payload-bytes",
      "external-payload-count",
      "external-payload-reference-count",
    ].do: | key/string |
      value := census.get key
      if value is int: result[key] += value
    by-type/List := census.get "by-type" --if-absent=: []
    by-type.do: | entry/Map |
      merge-census-entry type-counters entry["type"] entry
    by-class/List := census.get "by-class" --if-absent=: []
    by-class.do: | entry/Map |
      merge-census-entry class-counters "$(entry["class-id"])" entry
    by-liveness/List := census.get "by-gc-liveness" --if-absent=: []
    by-liveness.do: | entry/Map |
      merge-census-entry liveness-counters entry["state"] entry
  result["by-type"] = type-counters.values
  result["by-class"] = class-counters.values
  result["by-gc-liveness"] = liveness-counters.values
  result["complete"] = result["censused-chunks"] == chunks.size and
      result["complete-chunks"] == chunks.size
  result["authoritative"] = result["complete"] and
      result["authoritative-chunks"] == chunks.size
  result["runtime-state"] = runtime-state
  result["phase-diagnostics"] = phase-diagnostics
  return result

merge-census-entry counters/Map key/string source/Map -> none:
  target/Map? := counters.get key
  if not target:
    target = source.copy
    target["count"] = 0
    target["bytes"] = 0
    counters[key] = target
  target["count"] += source["count"]
  target["bytes"] += source["bytes"]

decode-chunks
    capture/toit-model.View space/int layout/Map diagnostics/List
    -> List:
  chunks := []
  list-offset := layout-field-offset layout "toit::Space" "chunk_list_"
  next-offset := layout-field-offset
      layout
      "DoubleLinkedListElement<toit::Chunk, 1>"
      "next_"
  anchor := space + list-offset
  next := read-pointer-if-captured capture (anchor + next-offset) diagnostics "chunks-next"
  seen := {}
  while next and next != anchor and chunks.size < MAX-RUNTIME-LIST:
    if seen.contains next:
      add-runtime-diagnostic diagnostics "CHUNK_LIST_CYCLE" next "chunks"
      break
    seen.add next
    start := read-pointer-if-captured
        capture
        (next + (layout-field-offset layout "toit::Chunk" "start_"))
        diagnostics
        "chunk-start"
    end := read-pointer-if-captured
        capture
        (next + (layout-field-offset layout "toit::Chunk" "end_"))
        diagnostics
        "chunk-end"
    chunks.add {
      "address": format.hex-address next,
      "start": pointer-address start,
      "end": pointer-address end,
      "size": start and end and end >= start ? end - start : null,
      "scavenge-pointer": pointer-address
          read-pointer-if-captured
              capture
              (next + (layout-field-offset layout "toit::Chunk" "scavenge_pointer_"))
              diagnostics
              "chunk-scavenge-pointer",
      "compaction-top": pointer-address
          read-pointer-if-captured
              capture
              (next + (layout-field-offset layout "toit::Chunk" "compaction_top_"))
              diagnostics
              "chunk-compaction-top",
    }
    next = read-pointer-if-captured
        capture
        (next + next-offset)
        diagnostics
        "chunk-next"
  if chunks.size == MAX-RUNTIME-LIST:
    add-runtime-diagnostic diagnostics "CHUNK_LIST_LIMIT" anchor "chunks"
  return chunks

validate-runtime-layout layout/Map -> none:
  layout-format := layout.get "format"
  layout-version := layout.get "format-version"
  pointer-size := layout.get "pointer-size"
  byte-order := layout.get "byte-order"
  if layout-format != "toit-runtime-layout" or
      layout-version != 1 or
      pointer-size != WORD-SIZE or
      byte-order != "little":
    throw "UNSUPPORTED_RUNTIME_LAYOUT"

layout-symbol-address layout/Map name/string -> int:
  symbols/Map := layout["symbols"]
  symbol/Map := symbols[name]
  if not symbol.get "present": throw "RUNTIME_SYMBOL_MISSING"
  return format.parse-address symbol["address"]

layout-field-offset layout/Map type-name/string field-name/string -> int:
  types/Map := layout["types"]
  type/Map := types[type-name]
  fields/List := type["fields"]
  result/int? := null
  fields.do: | field/Map |
    name := field.get "name"
    if name == field-name and field.contains "offset":
      result = field["offset"]
  if not result: throw "RUNTIME_LAYOUT_FIELD_MISSING"
  return result

layout-constant layout/Map name/string -> int:
  constants/Map := layout["constants"]
  value/int? := constants.get name
  if not value: throw "RUNTIME_LAYOUT_CONSTANT_MISSING"
  return value

read-pointer-if-captured
    capture/toit-model.View address/int diagnostics/List context/string
    -> int?:
  value := read-uint32-if-captured capture address diagnostics context
  if value == 0: return null
  return value

read-uint32-if-captured
    capture/toit-model.View address/int diagnostics/List context/string
    -> int?:
  if not is-captured capture address 4:
    add-runtime-diagnostic diagnostics "RUNTIME_WORD_NOT_CAPTURED" address context
    return null
  return read-uint32 capture address

read-int32-if-captured
    capture/toit-model.View address/int diagnostics/List context/string
    -> int?:
  value := read-uint32-if-captured capture address diagnostics context
  if not value: return null
  return signed-32 value

read-byte-if-captured
    capture/toit-model.View address/int diagnostics/List context/string
    -> int?:
  if not is-captured capture address 1:
    add-runtime-diagnostic diagnostics "RUNTIME_BYTE_NOT_CAPTURED" address context
    return null
  return (capture.read address 1)[0]

read-uint16-if-captured
    capture/toit-model.View address/int diagnostics/List context/string
    -> int?:
  if not is-captured capture address 2:
    add-runtime-diagnostic diagnostics "RUNTIME_HALF_WORD_NOT_CAPTURED" address context
    return null
  return read-uint16 capture address

pointer-address value/int? -> string?:
  return value ? format.hex-address value : null

add-runtime-diagnostic
    diagnostics/List code/string address/int context/string
    -> none:
  diagnostics.add {
    "code": code,
    "address": format.hex-address address,
    "context": context,
  }

is-captured capture/toit-model.View address/int length/int -> bool:
  if length <= 0: return false
  capture.regions.do: | region/target.MemoryRegion |
    if address >= region.address and address + length <= region.end-address:
      return true
  return false

ensure-supported-layout capture/toit-model.View -> none:
  target/Map := capture.metadata["target"]
  word-size := target.get "word-size"
  endianness := target.get "endianness"
  if word-size != WORD-SIZE or endianness != "little":
    throw "UNSUPPORTED_RUNTIME_LAYOUT"

add-layout-evidence
    capture/toit-model.View address/int type/string result/Map
    -> none:
  if type == "array":
    length := read-uint32 capture (address + 4)
    size := aligned-size 8 + length * WORD-SIZE
    result["length"] = length
    add-size-evidence capture address size result
    if result["size-valid"]:
      result["elements"] = preview-words capture (address + 8) length
    return

  if type == "byte-array":
    raw-length := read-int32 capture (address + 4)
    external := raw-length < 0
    length := external ? -1 - raw-length : raw-length
    size := external ? 16 : aligned-size 8 + length
    result["length"] = length
    result["external"] = external
    add-size-evidence capture address size result
    if external and result["size-valid"]:
      external-address := read-uint32 capture (address + 8)
      external-tag := read-uint32 capture (address + 12)
      result["external-address"] = format.hex-address external-address
      result["external-tag"] = external-tag
      captured := external-tag == 0 and length > 0 and
          is-captured capture external-address length
      result["external-content-captured"] = captured
      if captured:
        preview-size := min length MAX-PREVIEW-BYTES
        result["content-preview"] = format.bytes-to-hex
            capture.read external-address preview-size
        result["preview-truncated"] = preview-size < length
    else if not external and result["size-valid"]:
      preview-size := min length MAX-PREVIEW-BYTES
      result["content-preview"] = format.bytes-to-hex
          capture.read (address + 8) preview-size
      result["preview-truncated"] = preview-size < length
    return

  if type == "string":
    internal-length := read-uint16 capture (address + 6)
    external := internal-length == 0xffff
    length := external
        ? read-uint32 capture (address + 8)
        : internal-length
    size := external ? 16 : aligned-size 8 + length + 1
    result["length"] = length
    result["external"] = external
    add-size-evidence capture address size result
    if external and result["size-valid"]:
      external-address := read-uint32 capture (address + 12)
      result["external-address"] = format.hex-address external-address
      captured := length > 0 and is-captured capture external-address (length + 1)
      result["external-content-captured"] = captured
      if captured:
        preview-size := min length MAX-PREVIEW-BYTES
        result["content-preview"] = format.bytes-to-hex
            capture.read external-address preview-size
        result["preview-truncated"] = preview-size < length
    else if not external and result["size-valid"]:
      preview-size := min length MAX-PREVIEW-BYTES
      result["content-preview"] = format.bytes-to-hex
          capture.read (address + 8) preview-size
      result["preview-truncated"] = preview-size < length
    return

  if type == "double" or type == "large-integer":
    add-size-evidence capture address 12 result
    return

  if type == "free-list-region":
    size := read-uint32 capture (address + 4)
    add-size-evidence capture address size result
    return

  if type == "single-free-word":
    add-size-evidence capture address WORD-SIZE result
    return

  if type == "promoted-track":
    end := read-uint32 capture (address + 4)
    result["end-address"] = format.hex-address end
    add-size-evidence capture address (end - address) result
    return

  if type == "stack":
    result["length"] = read-uint32 capture (address + 8)
    result["top"] = read-uint32 capture (address + 12)
    result["try-top"] = read-uint32 capture (address + 16)
    result["size"] = null
    result["size-valid"] = null
    result["confidence"] = "layout-required"
    result["diagnostics"] = ["STACK_GUARD_LAYOUT_REQUIRED"]
    return

  result["size"] = null
  result["size-valid"] = null
  result["confidence"] = "layout-required"
  result["diagnostics"] = ["INSTANCE_SIZE_TABLE_REQUIRED"]

add-size-evidence
    capture/toit-model.View address/int size/int result/Map
    -> none:
  valid := size > 0 and is-captured capture address size
  result["size"] = size
  result["size-valid"] = valid
  if not valid:
    result["confidence"] = "low"
    result["diagnostics"] = ["OBJECT_SIZE_OUTSIDE_CAPTURE"]

preview-words
    capture/toit-model.View address/int count/int
    -> List:
  preview-count := min count 16
  result := []
  preview-count.repeat: | index |
    result.add (decode-word capture (address + index * WORD-SIZE))
  return result

normalize-object-address address/int -> int:
  tag := address & 3
  if tag == 0: return address
  if tag == 1: return address - 1
  if tag == 3: return address & ~3
  throw "INVALID_OBJECT_ADDRESS"

read-uint16 capture/toit-model.View address/int -> int:
  return LITTLE-ENDIAN.uint16 (capture.read address 2) 0

read-uint32 capture/toit-model.View address/int -> int:
  return LITTLE-ENDIAN.uint32 (capture.read address WORD-SIZE) 0

read-int32 capture/toit-model.View address/int -> int:
  return signed-32 (read-uint32 capture address)

signed-32 value/int -> int:
  return value >= 0x8000_0000 ? value - 0x1_0000_0000 : value

aligned-size value/int -> int:
  return (value + WORD-SIZE - 1) & ~(WORD-SIZE - 1)

hex-word value/int -> string:
  digits := (value & 0xffff_ffff).to-string --radix=16
  return "0x$("0" * (8 - digits.size))$digits"

matches-at haystack/ByteArray start/int needle/ByteArray -> bool:
  needle.size.repeat: | index |
    if haystack[start + index] != needle[index]: return false
  return true
