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

import encoding.hex

import .format as format
import .runtime as runtime
import .toit-model as toit-model

MAX-DEPTH ::= 8
MAX-OBJECTS ::= 500
MAX-ELEMENTS ::= 500
MAX-FIELDS ::= 1_024

/** Inspects an object using the program inferred from its process heap. */
inspect-process-object
    capture/toit-model.View object-heap-address/int target/int layout/Map
    max-depth/int=2 max-objects/int=100 max-elements/int=100
    -> Map:
  validate-limits max-depth max-objects max-elements
  decoded-runtime := runtime.decode-runtime capture layout
  selected := runtime.find-process-by-object-heap
      decoded-runtime
      object-heap-address
  if not selected: throw "OBJECT_HEAP_NOT_FOUND"
  process/Map := selected["process"]
  object-heap/Map := process["object-heap"]
  program-value := object-heap.get "program"
  if not program-value: throw "PROCESS_PROGRAM_NOT_AVAILABLE"
  program := format.parse-address program-value
  ranges := runtime.process-heap-ranges object-heap
  if ranges.is-empty: throw "PROCESS_HEAP_RANGES_NOT_AVAILABLE"
  result := inspect-object-graph
      capture
      program
      target
      layout
      ranges
      max-depth
      max-objects
      max-elements
  result["object-heap"] = format.hex-address object-heap-address
  result["program"] = format.hex-address program
  result["process-group-id"] = selected["process-group-id"]
  result["process-id"] = process["id"]
  if selected.get "container": result["container"] = selected["container"]
  return result

/** Builds a bounded, normalized graph rooted at one object. */
inspect-object-graph
    capture/toit-model.View program/int target/int layout/Map ranges/List
    max-depth/int=2 max-objects/int=100 max-elements/int=100
    -> Map:
  validate-limits max-depth max-objects max-elements
  program-layout := runtime.program-layout-for-program capture program layout
  if not program-layout: throw "PROGRAM_LAYOUT_NOT_AVAILABLE"
  root-address := runtime.normalize-object-address target
  ensure-root-belongs-to-process capture ranges root-address

  queue := [{"address": root-address, "depth": 0}]
  cursor := 0
  seen := {:}
  scheduled := {format.hex-address root-address: true}
  depth-omitted := {}
  objects := []
  diagnostics := []
  collection-truncations := 0
  while cursor < queue.size and objects.size < max-objects:
    pending/Map := queue[cursor++]
    address/int := pending["address"]
    key := format.hex-address address
    if seen.contains key: continue
    seen[key] = true
    depth/int := pending["depth"]
    decoded := inspect-one-object
        capture
        address
        program
        layout
        program-layout
        depth
        max-elements
    node/Map := decoded["node"]
    objects.add node
    targets/List := decoded["targets"]
    collection/Map? := node.get "collection"
    if collection and not (collection.get "complete" --if-absent=: true):
      collection-truncations++
    if depth >= max-depth:
      targets.do: | referenced/int |
        referenced-key := format.hex-address referenced
        if not scheduled.contains referenced-key:
          depth-omitted.add referenced-key
      continue
    targets.do: | referenced/int |
      referenced-key := format.hex-address referenced
      if not scheduled.contains referenced-key:
        scheduled[referenced-key] = true
        queue.add {"address": referenced, "depth": depth + 1}

  object-limit-reached := cursor < queue.size
  if object-limit-reached:
    diagnostics.add {
      "code": "OBJECT_INSPECTION_OBJECT_LIMIT",
      "pending-object-count": queue.size - cursor,
    }
  if not depth-omitted.is-empty:
    diagnostics.add {
      "code": "OBJECT_INSPECTION_DEPTH_LIMIT",
      "omitted-target-count": depth-omitted.size,
    }
  if collection-truncations > 0:
    diagnostics.add {
      "code": "OBJECT_INSPECTION_ELEMENT_LIMIT",
      "truncated-collection-count": collection-truncations,
    }
  complete := not object-limit-reached and depth-omitted.is-empty and
      collection-truncations == 0
  return {
    "root": format.hex-address root-address,
    "objects": objects,
    "object-count": objects.size,
    "complete": complete,
    "truncation": {
      "object-limit-reached": object-limit-reached,
      "depth-omitted-target-count": depth-omitted.size,
      "truncated-collection-count": collection-truncations,
    },
    "limits": {
      "max-depth": max-depth,
      "max-objects": max-objects,
      "max-elements-per-collection": max-elements,
    },
    "diagnostics": diagnostics,
  }

validate-limits depth/int objects/int elements/int -> none:
  if depth < 0 or depth > MAX-DEPTH: throw "INVALID_INSPECTION_DEPTH"
  if objects <= 0 or objects > MAX-OBJECTS:
    throw "INVALID_INSPECTION_OBJECT_LIMIT"
  if elements <= 0 or elements > MAX-ELEMENTS:
    throw "INVALID_INSPECTION_ELEMENT_LIMIT"

ensure-root-belongs-to-process
    capture/toit-model.View ranges/List address/int
    -> none:
  if runtime.address-in-ranges ranges address: return
  region := runtime.region-containing capture address
  if region and (runtime.storage-for-region region) == "flash": return
  throw "OBJECT_NOT_IN_SELECTED_PROCESS"

inspect-one-object
    capture/toit-model.View address/int program/int layout/Map program-layout/Map
    depth/int max-elements/int
    -> Map:
  object := runtime.decode-object-with-program capture address program layout
  class-info := runtime.class-info-for-id
      program-layout
      object.get "class-id"
  validate-object-layout object class-info
  class-name := class-info ? class-info.get "name" : null
  node := {
    "address": object["address"],
    "depth": depth,
    "state": object["state"],
    "type": object.get "type",
    "class-id": object.get "class-id",
    "class-name": class-name,
    "size": object.get "size",
    "size-valid": object.get "size-valid",
    "confidence": object.get "confidence",
  }
  region := runtime.region-containing capture address
  if region:
    node["storage"] = runtime.storage-for-region region
    node["region"] = {
      "id": region.id,
      "name": region.name,
      "kind": region.kind,
      "permissions": region.permissions,
    }
  else:
    node["storage"] = "uncaptured"
  [
    "length",
    "external",
    "external-address",
    "external-content-captured",
    "content-preview",
    "preview-truncated",
  ].do: | key/string |
    if object.contains key: node[key] = object[key]
  if (object.get "type") == "string" and object.contains "content-preview":
    node["text-preview"] = text-preview object["content-preview"]

  targets := []
  if object["state"] != "normal-header":
    if object.contains "diagnostics": node["diagnostics"] = object["diagnostics"]
    return {"node": node, "targets": targets}

  type := object.get "type"
  fields := []
  if type == "instance" or type == "task" or type == "oddball":
    fields = inspect-fields
        capture
        address
        object
        class-info
        program
        layout
        program-layout
        targets
    node["fields"] = fields

  if type == "array":
    node["collection"] = inspect-array
        capture
        address
        object["length"]
        program
        layout
        program-layout
        max-elements
        targets
  else if class-name == "List_":
    node["collection"] = inspect-list
        capture
        fields
        program
        layout
        program-layout
        max-elements
        targets
  else if class-name == "Map" or class-name == "Set":
    node["collection"] = inspect-hashed-collection
        capture
        class-name
        fields
        program
        layout
        program-layout
        max-elements
        targets
  return {"node": node, "targets": targets}

validate-object-layout object/Map class-info/Map? -> none:
  state := object.get "state"
  type := object.get "type"
  if state != "normal-header" or
      (type != "instance" and type != "task" and type != "oddball"):
    return
  if not class-info: throw "OBJECT_CLASS_LAYOUT_NOT_AVAILABLE"
  size := object.get "size"
  fields/List := class-info.get "all-fields" --if-absent=: []
  if not size is int or size < runtime.WORD-SIZE:
    throw "PROGRAM_OBJECT_LAYOUT_MISMATCH"
  field-count := (size - runtime.WORD-SIZE) / runtime.WORD-SIZE
  if field-count != fields.size or field-count > MAX-FIELDS:
    throw "PROGRAM_OBJECT_LAYOUT_MISMATCH"
  declared-size := class-info.get "instance-size"
  if declared-size is int and declared-size > 0 and declared-size != size:
    throw "PROGRAM_OBJECT_LAYOUT_MISMATCH"

inspect-fields
    capture/toit-model.View address/int object/Map class-info/Map?
    program/int layout/Map program-layout/Map targets/List
    -> List:
  size/int := object["size"]
  count := (size - runtime.WORD-SIZE) / runtime.WORD-SIZE
  names/List := class-info
      ? class-info.get "all-fields" --if-absent=: []
      : []
  result := []
  count.repeat: | index |
    slot := address + runtime.WORD-SIZE + index * runtime.WORD-SIZE
    value := inspect-value
        capture
        slot
        program
        layout
        program-layout
        targets
    result.add {
      "name": names[index],
      "index": index,
      "offset": runtime.WORD-SIZE + index * runtime.WORD-SIZE,
      "value": value,
    }
  return result

inspect-array
    capture/toit-model.View address/int length/int program/int layout/Map
    program-layout/Map max-elements/int targets/List
    -> Map:
  count := min length max-elements
  elements := []
  count.repeat: | index |
    elements.add {
      "index": index,
      "value": inspect-value
          capture
          address + 2 * runtime.WORD-SIZE + index * runtime.WORD-SIZE
          program
          layout
          program-layout
          targets,
    }
  return {
    "kind": "array",
    "length": length,
    "capacity": length,
    "elements": elements,
    "scanned-elements": count,
    "omitted-elements": length - count,
    "complete": count == length,
  }

inspect-list
    capture/toit-model.View fields/List program/int layout/Map
    program-layout/Map max-elements/int targets/List
    -> Map:
  size := smi-field fields "size_"
  array-address := reference-field fields "array_"
  if size == null or not array-address:
    return {
      "kind": "list",
      "state": "unavailable",
      "diagnostic": "LIST_LAYOUT_NOT_AVAILABLE",
    }
  array := decode-array-structure capture array-address program layout
  capacity := array["length"]
  safe-size := min size capacity
  count := min safe-size max-elements
  elements := []
  count.repeat: | index |
    elements.add {
      "index": index,
      "value": inspect-value
          capture
          array-address + 2 * runtime.WORD-SIZE + index * runtime.WORD-SIZE
          program
          layout
          program-layout
          targets,
    }
  return {
    "kind": "list",
    "length": size,
    "capacity": capacity,
    "elements": elements,
    "scanned-elements": count,
    "omitted-elements": max 0 (size - count),
    "complete": size <= capacity and count == size,
    "structurally-valid": size >= 0 and size <= capacity,
  }

inspect-hashed-collection
    capture/toit-model.View class-name/string fields/List program/int layout/Map
    program-layout/Map max-elements/int targets/List
    -> Map:
  kind := class-name == "Map" ? "map" : "set"
  logical-size := smi-field fields "size_"
  index-spaces-left := smi-field fields "index-spaces-left_"
  index-address := reference-field fields "index_"
  backing-address := reference-field fields "backing_"
  result := {
    "kind": kind,
    "length": logical-size,
    "index-spaces-left": index-spaces-left,
    "index-capacity": collection-array-capacity
        capture
        index-address
        program
        layout,
  }
  if not backing-address or is-null-object
      capture
      backing-address
      program
      layout
      program-layout:
    result["backing-used-slots"] = 0
    result["backing-capacity"] = 0
    result[kind == "map" ? "entries" : "elements"] = []
    result["complete"] = logical-size == 0
    return result

  backing-fields := decode-named-fields
      capture
      backing-address
      program
      layout
      program-layout
  used := smi-field backing-fields "size_"
  array-address := reference-field backing-fields "array_"
  if used == null or not array-address:
    result["state"] = "unavailable"
    result["diagnostic"] = "COLLECTION_BACKING_LAYOUT_NOT_AVAILABLE"
    return result
  array := decode-array-structure capture array-address program layout
  capacity := array["length"]
  safe-used := min used capacity
  step := kind == "map" ? 2 : 1
  scan-slots := min safe-used (max-elements * step)
  if kind == "map" and (scan-slots & 1) != 0: scan-slots--
  items := []
  tombstones := 0
  for index := 0; index < scan-slots; index += step:
    key := inspect-value
        capture
        array-address + 2 * runtime.WORD-SIZE + index * runtime.WORD-SIZE
        program
        layout
        program-layout
        targets
    if is-tombstone key:
      tombstones += step
      continue
    if kind == "map":
      value := inspect-value
          capture
          array-address +
              2 * runtime.WORD-SIZE + (index + 1) * runtime.WORD-SIZE
          program
          layout
          program-layout
          targets
      items.add {
        "backing-index": index,
        "key": key,
        "value": value,
      }
    else:
      items.add {"backing-index": index, "value": key}
  result["backing-used-slots"] = used
  result["backing-capacity"] = capacity
  result["observed-tombstone-slots"] = tombstones
  result["scanned-backing-slots"] = scan-slots
  result["omitted-backing-slots"] = max 0 (used - scan-slots)
  result[kind == "map" ? "entries" : "elements"] = items
  result["complete"] = used <= capacity and scan-slots == used
  result["structurally-valid"] = used >= 0 and used <= capacity and
      (kind != "map" or (used & 1) == 0)
  return result

decode-named-fields
    capture/toit-model.View address/int program/int layout/Map program-layout/Map
    -> List:
  object := runtime.decode-object-with-program capture address program layout
  class-info := runtime.class-info-for-id
      program-layout
      object.get "class-id"
  validate-object-layout object class-info
  ignored-targets := []
  return inspect-fields
      capture
      address
      object
      class-info
      program
      layout
      program-layout
      ignored-targets

decode-array-structure
    capture/toit-model.View address/int program/int layout/Map
    -> Map:
  object := runtime.decode-object-with-program capture address program layout
  if (object.get "state") != "normal-header" or
      (object.get "type") != "array":
    throw "COLLECTION_BACKING_ARRAY_EXPECTED"
  return object

collection-array-capacity
    capture/toit-model.View address/int? program/int layout/Map
    -> int?:
  if not address: return 0
  object/Map? := null
  exception := catch:
    object = decode-array-structure capture address program layout
  if exception: return null
  return object["length"]

inspect-value
    capture/toit-model.View slot/int program/int layout/Map program-layout/Map
    targets/List
    -> Map:
  value := runtime.decode-word capture slot
  runtime.decorate-runtime-value capture value program layout program-layout
  summary/Map? := value.get "object"
  if summary and (summary.get "type") == "string" and
      summary.contains "content-preview":
    text := text-preview summary["content-preview"]
    summary["text-preview"] = text
    storage := value.get "target-storage" --if-absent=: "unknown-storage"
    value["display"] = "\"$text\" @ $(summary["address"]) ($storage)"
  candidate := value.get "candidate-kind"
  if (candidate == "heap-reference" or candidate == "marked-heap-reference") and
      (value.get "target-captured" --if-absent=: false):
    targets.add (format.parse-address value["object-address"])
  return value

smi-field fields/List name/string -> int?:
  field := named-field fields name
  if not field: return null
  value/Map := field["value"]
  return (value.get "candidate-kind") == "smi" ? value.get "value" : null

reference-field fields/List name/string -> int?:
  field := named-field fields name
  if not field: return null
  value/Map := field["value"]
  candidate := value.get "candidate-kind"
  if candidate != "heap-reference" and candidate != "marked-heap-reference":
    return null
  if not (value.get "target-captured" --if-absent=: false): return null
  return format.parse-address value["object-address"]

named-field fields/List name/string -> Map?:
  fields.do: | field/Map |
    if field["name"] == name: return field
  return null

is-null-object
    capture/toit-model.View address/int program/int layout/Map program-layout/Map
    -> bool:
  object := runtime.decode-object-with-program capture address program layout
  info := runtime.class-info-for-id program-layout (object.get "class-id")
  return info and (info.get "name") == "Null_"

is-tombstone value/Map -> bool:
  object/Map? := value.get "object"
  if not object: return false
  name := object.get "class-name"
  return name == "Tombstone_" or name == "LargeTombstone_"

text-preview encoded/string -> string:
  return (hex.decode encoded).to-string-non-throwing
