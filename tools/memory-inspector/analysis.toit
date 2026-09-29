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

/**
Answers questions about a memory capture. All results are JSON-compatible
  maps and lists, so they can be printed for tools and agents.
*/

import .capture
import .heap
import .names

hex address/int -> string: return "0x$(%x address)"

/** The owner of the blocks that the capture itself uses. */
CAPTURE-OWNER ::= "memory capture"

/** How an object is reached from the roots of its process. */
class Reference:
  /** The referencing object, or null if the object is referenced by a root. */
  from/HeapObject?
  /** The field (or element, or stack slot) index in $from. */
  index/int
  root/Root?

  constructor.field .from .index:
    root = null

  constructor.root .root:
    from = null
    index = 0

class Analysis:
  capture/Capture
  names/Names
  heaps_/Map ::= {:}      // From process id to $Heap.
  reached_/Map ::= {:}    // From process id to a map from object address to $Reference.

  constructor .capture .names:

  heap process/ProcessInfo -> Heap:
    return heaps_.get process.id --init=: Heap capture process

  program-of process/ProcessInfo -> ProgramInfo:
    return capture.programs[process.program-address]

  process-by-id id/int -> ProcessInfo:
    return capture.process-by-id id

  /**
  Returns a map from the address of every object that is reachable from the
    roots of the process to the first reference (in breadth-first order)
    that reaches it.
  */
  reached process/ProcessInfo -> Map:
    return reached_.get process.id --init=:
      heap := heap process
      result := {:}
      queue := []
      process.roots.do: | root/Root |
        object := heap.object-for-value root.value
        if object and not result.contains object.address:
          result[object.address] = Reference.root root
          queue.add object
      position := 0
      while position < queue.size:
        object/HeapObject := queue[position++]
        heap.pointer-fields object: | index value |
          referenced := heap.object-for-value value
          if referenced and not result.contains referenced.address:
            result[referenced.address] = Reference.field object index
            queue.add referenced
      result

  sorted-blocks_/List? := null

  /** Returns the malloc block that contains the given address, or null. */
  malloc-block-containing address/int -> MallocBlock?:
    if not sorted-blocks_:
      sorted-blocks_ = capture.malloc-blocks.sort: | a b | a.address.compare-to b.address
    blocks := sorted-blocks_
    low := 0
    high := blocks.size
    while low < high:
      middle := (low + high) / 2
      block/MallocBlock := blocks[middle]
      if address < block.address: high = middle
      else if address >= block.end: low = middle + 1
      else: return block
    return null

  /**
  Assigns malloc blocks to the processes that own them.
  A process owns the blocks that hold its heap chunks and the external
    content of its objects, even when another process allocated them (for
    example, when a byte array was sent to it). Other blocks belong to the
    process that allocated them, or on whose behalf they were allocated, as
    recorded in their malloc tag. The blocks the capture uses belong to the
    capture.
  Returns a map from block address to owner ("process <id>" or $CAPTURE-OWNER).
  */
  malloc-owners -> Map:
    owners := {:}
    capture.malloc-blocks.do: | block/MallocBlock |
      if block.process-id: owners[block.address] = "process $block.process-id"
    capture.processes.do: | process/ProcessInfo |
      process.chunks.do: | chunk/Chunk |
        block := malloc-block-containing chunk.address
        if block: owners[block.address] = "process $process.id"
      (heap process).objects.do: | object/HeapObject |
        if object.external-address:
          block := malloc-block-containing object.external-address
          if block: owners[block.address] = "process $process.id"
    capture.capture-addresses.do: | address |
      block := malloc-block-containing address
      if block: owners[block.address] = CAPTURE-OWNER
    return owners

  owned-bytes_/Map? := null

  /** The number of system-heap bytes that the process owns, or null without a malloc map. */
  system-heap-bytes process/ProcessInfo -> int?:
    if capture.malloc-blocks.is-empty: return null
    if not owned-bytes_:
      owned-bytes_ = {:}
      owners := malloc-owners
      capture.malloc-blocks.do: | block/MallocBlock |
        owner := owners.get block.address
        if owner: owned-bytes_[owner] = (owned-bytes_.get owner --if-absent=: 0) + block.size
    return owned-bytes_.get "process $process.id" --if-absent=: 0

  summary -> Map:
    result := {
      "capture": capture-info,
      "system-heaps": capture.system-heaps.map: | heap/SystemHeap | {
        "name": heap.name,
        "total": heap.total,
        "free": heap.free,
        "largest-free-block": heap.largest-free-block,
      },
    }
    if not capture.malloc-blocks.is-empty:
      result["malloc"] = malloc-summary --owners=malloc-owners
    result["processes"] = capture.processes.map: | process/ProcessInfo |
      process-summary process
    return result

  capture-info -> Map:
    return {
      "platform": capture.platform,
      "version": capture.version,
      "word-size": capture.word-size,
      "reason": capture.reason,
      "complete": capture.problems.is-empty,
      "problems": capture.problems,
    }

  /**
  Summarizes the system heap by owner (a Toit process, or the malloc tag of
    blocks that no process owns).
  */
  malloc-summary --owners/Map -> Map:
    by-owner := {:}
    free-bytes := 0
    free-count := 0
    largest-free := 0
    overhead := 0
    capture.malloc-blocks.do: | block/MallocBlock |
      tag-name := capture.malloc-tag-name block.tag
      if tag-name == "free":
        free-bytes += block.size
        free-count++
        largest-free = max largest-free block.size
        continue.do
      if tag-name == "heap overhead":
        overhead += block.size
        continue.do
      owner := owners.get block.address
      key := owner or tag-name
      entry := by-owner.get key --init=: {
        "owner": key,
        "bytes": 0,
        "blocks": 0,
      }
      entry["bytes"] += block.size
      entry["blocks"] += 1
      if owner:
        by-tag := entry.get "by-tag" --init=: {:}
        by-tag[tag-name] = (by-tag.get tag-name --if-absent=: 0) + block.size
    used := by-owner.values.sort: | a b | b["bytes"].compare-to a["bytes"]
    return {
      "used": used,
      "free": { "bytes": free-bytes, "blocks": free-count, "largest-block": largest-free },
      "allocator-overhead": overhead,
    }

  /**
  Returns the blocks of the system heap with the given owner ("process <id>"
    or a malloc tag for blocks without a process) and tag, largest first.
  */
  malloc-blocks --owner/string? --tag/string? --limit/int -> List:
    owners := malloc-owners
    result := []
    capture.malloc-blocks.do: | block/MallocBlock |
      tag-name := capture.malloc-tag-name block.tag
      if tag-name == "free" or tag-name == "heap overhead": continue.do
      block-owner := (owners.get block.address) or tag-name
      if owner and owner != block-owner: continue.do
      if tag and tag != tag-name: continue.do
      entry := {
        "address": hex block.address,
        "size": block.size,
        "tag": tag-name,
        "owner": block-owner,
      }
      if block.process-id: entry["allocated-by"] = "process $block.process-id"
      result.add entry
    result.sort --in-place: | a b | b["size"].compare-to a["size"]
    return result[..min limit result.size]

  process-summary process/ProcessInfo -> Map:
    program := program-of process
    result := {
      "id": process.id,
      "group": process.group-id,
      "program": program.uuid-string,
      "has-snapshot": names.has-snapshot program,
      "heap-bytes": process.heap-bytes,
      "external-bytes": process.external-bytes,
    }
    system-heap := system-heap-bytes process
    if system-heap: result["system-heap-bytes"] = system-heap
    heap := heap process
    reached := reached process
    live-bytes := 0
    garbage-bytes := 0
    heap.objects.do: | object/HeapObject |
      if reached.contains object.address: live-bytes += object.size
      else: garbage-bytes += object.size
    chunk-bytes := 0
    process.chunks.do: chunk-bytes += it.size
    result["chunk-bytes"] = chunk-bytes
    result["live-object-bytes"] = live-bytes
    result["unreachable-object-bytes"] = garbage-bytes
    classes := census process
    result["top-classes"] = classes[..min 5 classes.size]
    if not heap.problems.is-empty: result["problems"] = heap.problems
    return result

  /**
  Returns the classes of the objects in the heap of the process, sorted by
    the number of bytes they use (including external content).
  */
  census process/ProcessInfo -> List:
    heap := heap process
    reached := reached process
    program := program-of process
    by-class := {:}
    heap.objects.do: | object/HeapObject |
      entry := by-class.get object.class-id --init=: {
        "class": names.class-name program object.class-id,
        "class-id": object.class-id,
        "count": 0,
        "bytes": 0,
        "external-bytes": 0,
        "live-count": 0,
        "live-bytes": 0,
        "live-external-bytes": 0,
      }
      entry["count"] += 1
      entry["bytes"] += object.size
      external := external-size object
      entry["external-bytes"] += external
      if reached.contains object.address:
        entry["live-count"] += 1
        entry["live-bytes"] += object.size
        entry["live-external-bytes"] += external
    result := by-class.values
    result.sort --in-place: | a b |
      (b["bytes"] + b["external-bytes"]).compare-to (a["bytes"] + a["external-bytes"])
    return result

  /**
  Returns the number of bytes the external content of an object uses in the
    system heap: the size of the malloc block that holds it.
  Content outside the system heap (for example in flash) doesn't count.
  Without a malloc map (on the host) the size is taken from the object.
  */
  external-size object/HeapObject -> int:
    if not object.external-address: return 0
    if capture.malloc-blocks.is-empty: return object.external-size or 0
    block := malloc-block-containing object.external-address
    return block ? block.size : 0

  /** Returns the objects of the given class (by name or id), largest first. */
  objects process/ProcessInfo --class-name/string --limit/int -> List:
    heap := heap process
    program := program-of process
    reached := reached process
    matching := heap.objects.filter: | object/HeapObject |
      (names.class-name program object.class-id) == class-name
    matching.sort --in-place: | a b |
      (b.size + (external-size b)).compare-to (a.size + (external-size a))
    return matching[..min limit matching.size].map: | object/HeapObject |
      describe-object process object --live=(reached.contains object.address)

  describe-object process/ProcessInfo object/HeapObject --live/bool -> Map:
    program := program-of process
    result := {
      "address": hex object.address,
      "class": names.class-name program object.class-id,
      "size": object.size,
      "live": live,
    }
    if object.external-address:
      result["external"] = {
        "address": hex object.external-address,
        "heap-bytes": external-size object,
      }
      if object.external-size: result["external"]["size"] = object.external-size
      if object.struct-tag and object.struct-tag != capture.layout["raw-byte-tag"]:
        result["external"]["struct"] = capture.struct-tag-names.get object.struct-tag
            --if-absent=: "tag $object.struct-tag"
    preview := preview_ (heap process) object
    if preview: result["preview"] = preview
    return result

  preview_ heap/Heap object/HeapObject -> string?:
    content := heap.content object
    if not content: return null
    shown := content[..min 40 content.size]
    if object.class-tag == capture.layout["string-tag"]:
      text := shown.to-string-non-throwing
      return content.size > shown.size ? "$text..." : text
    return "$content.size bytes"

  /** Describes a value in a field or root. */
  describe-value process/ProcessInfo value/int -> Map:
    heap := heap process
    program := program-of process
    if heap.is-smi value: return { "smi": (heap.signed value) >> capture.layout["smi-tag-size"] }
    if value == program.null-value: return { "literal": "null" }
    if value == program.true-value: return { "literal": "true" }
    if value == program.false-value: return { "literal": "false" }
    object := heap.object-for-value value
    if object:
      result := { "object": hex object.address, "class": names.class-name program object.class-id }
      preview := preview_ heap object
      if preview: result["preview"] = preview
      return result
    if heap.is-heap-pointer value and program.contains value:
      return { "program-object": hex value }
    return { "raw": hex value }

  /** Describes an object with all its fields. */
  inspect process/ProcessInfo address/int --limit/int -> Map:
    heap := heap process
    object := heap.object-at address
    if not object: throw "no object at $(hex address) in process $process.id"
    reached := reached process
    result := describe-object process object --live=(reached.contains address)
    field-names := null
    if object.class-tag == capture.layout["instance-tag"] or object.class-tag == capture.layout["task-tag"]:
      field-names = names.field-names (program-of process) object.class-id
    fields := []
    heap.pointer-fields object: | index value |
      if fields.size < limit:
        entry := { "index": index, "value": describe-value process value }
        if field-names and index < field-names.size: entry["name"] = field-names[index]
        fields.add entry
    result["fields"] = fields
    return result

  /** Returns the chain of references from a root to the object. */
  path process/ProcessInfo address/int -> List:
    heap := heap process
    object := heap.object-at address
    if not object: throw "no object at $(hex address) in process $process.id"
    reached := reached process
    if not reached.contains address: return []
    program := program-of process
    steps := []
    current := object
    while true:
      reference/Reference := reached[current.address]
      step := describe-object process current --live
      if reference.root:
        root := reference.root
        step["root"] = root.kind-name
        if root.kind == GLOBAL-ROOT: step["global"] = names.global-name program root.index
        steps.add step
        break
      from := reference.from
      field-names := null
      if from.class-tag == capture.layout["instance-tag"] or from.class-tag == capture.layout["task-tag"]:
        field-names = names.field-names program from.class-id
      step["referenced-by-field"] = (field-names and reference.index < field-names.size)
          ? field-names[reference.index]
          : reference.index
      steps.add step
      current = from
    return List steps.size: steps[steps.size - 1 - it]

  /** Returns the objects that directly reference the object at the given address. */
  retainers process/ProcessInfo address/int --limit/int -> List:
    heap := heap process
    reached := reached process
    result := []
    process.roots.do: | root/Root |
      if (heap.object-for-value root.value) and (heap.object-for-value root.value).address == address:
        entry := { "root": root.kind-name, "index": root.index }
        if root.kind == GLOBAL-ROOT: entry["global"] = names.global-name (program-of process) root.index
        result.add entry
    heap.objects.do: | object/HeapObject |
      if result.size >= limit: return result
      heap.pointer-fields object: | index value |
        referenced := heap.object-for-value value
        if referenced and referenced.address == address:
          entry := describe-object process object --live=(reached.contains object.address)
          entry["field"] = index
          result.add entry
    return result

/**
Compares two captures. Processes are matched by id and program.
Positive numbers mean that $after uses more than $before.
*/
diff before/Analysis after/Analysis -> Map:
  result := {:}
  if not before.capture.malloc-blocks.is-empty and not after.capture.malloc-blocks.is-empty:
    by-tag := {:}
    add := : | analysis/Analysis sign/int |
      owners := analysis.malloc-owners
      analysis.capture.malloc-blocks.do: | block/MallocBlock |
        // The capture's own buffers are not interesting.
        if (owners.get block.address) == CAPTURE-OWNER: continue.do
        name := analysis.capture.malloc-tag-name block.tag
        by-tag[name] = (by-tag.get name --if-absent=: 0) + sign * block.size
    add.call before -1
    add.call after 1
    changes := []
    by-tag.do: | name delta | if delta != 0: changes.add { "tag": name, "bytes": delta }
    changes.sort --in-place: | a b | b["bytes"].abs.compare-to a["bytes"].abs
    result["malloc-by-tag"] = changes

  processes := []
  after.capture.processes.do: | process/ProcessInfo |
    old/ProcessInfo? := null
    before.capture.processes.do: | candidate/ProcessInfo |
      if candidate.id == process.id and
          (before.program-of candidate).uuid == (after.program-of process).uuid:
        old = candidate
    if not old: continue.do
    // The programs are the same, so the class ids match. Only live objects
    // count, so that garbage doesn't hide or fake growth.
    classes := {:}
    (before.census old).do: | entry/Map |
      classes[entry["class-id"]] = {
        "class": entry["class"],
        "count": -entry["live-count"],
        "bytes": -(entry["live-bytes"] + entry["live-external-bytes"]),
      }
    (after.census process).do: | entry/Map |
      change := classes.get entry["class-id"] --init=: { "class": entry["class"], "count": 0, "bytes": 0 }
      change["count"] += entry["live-count"]
      change["bytes"] += entry["live-bytes"] + entry["live-external-bytes"]
    changed := classes.values.filter: it["count"] != 0 or it["bytes"] != 0
    changed.sort --in-place: | a b | b["bytes"].abs.compare-to a["bytes"].abs
    entry := {
      "id": process.id,
      "heap-bytes": process.heap-bytes - old.heap-bytes,
      "external-bytes": process.external-bytes - old.external-bytes,
    }
    before-system-heap := before.system-heap-bytes old
    after-system-heap := after.system-heap-bytes process
    if before-system-heap and after-system-heap:
      entry["system-heap-bytes"] = after-system-heap - before-system-heap
    entry["classes"] = changed
    processes.add entry
  result["processes"] = processes
  return result
