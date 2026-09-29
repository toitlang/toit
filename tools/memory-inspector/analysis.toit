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
  Assigns malloc blocks to their owners: a process owns the blocks that hold
    its heap chunks and the external content of its objects. The blocks the
    capture uses belong to the capture.
  Returns a map from block address to owner ("process <id>" or $CAPTURE-OWNER).
  */
  malloc-owners -> Map:
    owners := {:}
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
    used := by-owner.values.sort: | a b | b["bytes"].compare-to a["bytes"]
    return {
      "used": used,
      "free": { "bytes": free-bytes, "blocks": free-count, "largest-block": largest-free },
      "allocator-overhead": overhead,
    }

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
