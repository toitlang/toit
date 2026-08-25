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

import .format as format
import .compact-allocator as compact-allocator
import .capture-scope as scope-planner
import .description as description
import .runtime as runtime
import .target as target
import io show LITTLE-ENDIAN

SUPPORTED-NATIVE-OWNERSHIP-DECODERS ::= [
  "toit-gc-metadata",
  "toit-gc-spare-space",
  "toit-scheduler-threads",
  "toit-event-sources",
  "newlib-stdio",
  "gpio-statics",
  "platform-statics",
  "freertos-tasks",
  "physical-memory-regions",
]

ownership-decoder-version ownership/Map id/string -> int?:
  decoders/List := ownership.get "decoders" --if-absent=: []
  decoders.do: | decoder/Map |
    if (decoder.get "id") == id: return decoder.get "version"
  return null

ownership-decoder-enabled ownership/Map id/string -> bool:
  return (ownership-decoder-version ownership id) == 1

decoder-not-enumerated runtime-layout/Map? ownership/Map id/string -> Map:
  if not runtime-layout:
    return {"state": "not-enumerated", "reason": "RUNTIME_LAYOUT_NOT_AVAILABLE"}
  version := ownership-decoder-version ownership id
  if not version:
    return {
      "state": "not-enumerated",
      "reason": "NATIVE_OWNERSHIP_DECODER_NOT_DECLARED",
      "decoder": id,
    }
  return {
    "state": "not-enumerated",
    "reason": "NATIVE_OWNERSHIP_DECODER_NOT_SUPPORTED",
    "decoder": id,
    "version": version,
  }

unsupported-ownership-decoders ownership/Map -> List:
  result := []
  decoders/List := ownership.get "decoders" --if-absent=: []
  decoders.do: | decoder/Map |
    id/string := decoder["id"]
    version/int := decoder["version"]
    if version != 1 or not SUPPORTED-NATIVE-OWNERSHIP-DECODERS.contains id:
      result.add {"id": id, "version": version}
  return result

/** Builds native and Toit ownership accounting from currently decoded facts. */
build
    memory/target.Target
    decoded-runtime/Map
    scope/Map?
    runtime-layout/Map?=null
    inspector-description/Map?=null
    -> Map:
  ownership/Map := inspector-description
      ? inspector-description["native-ownership"]
      : description.native-ownership-v1
  allocator := runtime-layout
      ? compact-allocator.decode memory runtime-layout
      : {
        "state": "unavailable",
        "allocations": [],
        "heaps": [],
        "diagnostics": [{"code": "COMPACT_ALLOCATOR_LAYOUT_UNAVAILABLE"}],
      }
  allocations/List := allocator["allocations"]
  roots := []
  edges := []
  diagnostics/List := allocator["diagnostics"].copy
  unsupported-decoders := unsupported-ownership-decoders ownership
  unsupported-decoders.do: | decoder/Map |
    diagnostics.add {
      "code": "NATIVE_OWNERSHIP_DECODER_NOT_SUPPORTED",
      "decoder": decoder["id"],
      "version": decoder["version"],
    }
  allocator-complete := allocator["state"] == "complete"
  physical-memory := add-physical-memory-regions
      allocations
      roots
      allocator
      ownership

  captured-region-bytes := 0
  memory.regions.do: | region/target.MemoryRegion |
    captured-region-bytes += region.size

  decoded-runtime["process-groups"].do: | group/Map |
    group-id := group["id"]
    container-name := process-group-container-name group
    group-component := container-name
        ? "toit-container:$container-name"
        : "toit-process-group:$group-id"
    group-address := group.get "address"
    if group-address is string:
      add-address-root
          allocations
          roots
          group-component
          "process-group-control"
          (format.parse-address group-address)
          "scheduler-process-group-list"
    group["processes"].do: | process/Map |
      process-id := process["id"]
      component := process-component group-id process-id container-name
      process-address := process.get "address"
      if process-address is string:
        add-address-root
            allocations
            roots
            component
            "process-control"
            (format.parse-address process-address)
            "process-group-process-list"
      heap/Map := process["object-heap"]
      globals/Map? := heap.get "globals"
      if globals:
        globals-address := globals.get "table-address"
        if globals-address is string:
          add-address-root
              allocations
              roots
              component
              "global-variable-table"
              (format.parse-address globals-address)
              "object-heap.global_variables_"
      add-program-heap allocations roots heap component
      add-space allocations roots heap "old-space" component
      add-space allocations roots heap "new-space" component

  gc-metadata := runtime-layout and ownership-decoder-enabled ownership "toit-gc-metadata"
      ? add-gc-metadata memory allocations roots runtime-layout
      : decoder-not-enumerated runtime-layout ownership "toit-gc-metadata"
  gc-spare-chunk := runtime-layout and ownership-decoder-enabled ownership "toit-gc-spare-space"
      ? add-gc-spare-chunk memory allocations roots runtime-layout
      : decoder-not-enumerated runtime-layout ownership "toit-gc-spare-space"
  allocator-heaps := add-allocator-heap-backing allocations roots allocator
  scheduler-threads := runtime-layout and ownership-decoder-enabled ownership "toit-scheduler-threads"
      ? add-scheduler-thread-roots memory allocations roots runtime-layout
      : decoder-not-enumerated runtime-layout ownership "toit-scheduler-threads"
  event-sources := runtime-layout and ownership-decoder-enabled ownership "toit-event-sources"
      ? add-event-source-roots memory allocations roots runtime-layout ownership
      : decoder-not-enumerated runtime-layout ownership "toit-event-sources"
  libc := runtime-layout and ownership-decoder-enabled ownership "newlib-stdio"
      ? add-global-newlib-roots memory allocations roots runtime-layout
      : decoder-not-enumerated runtime-layout ownership "newlib-stdio"
  gpio := runtime-layout and ownership-decoder-enabled ownership "gpio-statics"
      ? add-gpio-static-roots memory allocations roots runtime-layout
      : decoder-not-enumerated runtime-layout ownership "gpio-statics"
  platform-statics := runtime-layout and ownership-decoder-enabled ownership "platform-statics"
      ? add-platform-static-roots memory allocations roots runtime-layout ownership
      : decoder-not-enumerated runtime-layout ownership "platform-statics"
  freertos-tasks := runtime-layout and ownership-decoder-enabled ownership "freertos-tasks"
      ? add-freertos-task-roots memory allocations roots runtime-layout scheduler-threads
          event-sources
      : decoder-not-enumerated runtime-layout ownership "freertos-tasks"

  ownership-evidence/Map? := null
  if scope and (scope.get "kind") == "process-group":
    selected/Map := scope["selected"]
    processes := []
    selected-processes/List := selected.get "processes" --if-absent=: []
    selected-processes.do: | process/Map |
      processes.add {
        "process-group-id": selected["id"],
        "process": process,
      }
    ownership-evidence = {
      "state": (scope.get "unresolved" --if-absent=: []).is-empty
          ? "complete"
          : "partial",
      "source": "capture-scope",
      "processes": processes,
      "unresolved": scope.get "unresolved" --if-absent=: [],
    }
  else if runtime-layout:
    ownership-evidence = discover-full-device-ownership
        memory
        decoded-runtime
        runtime-layout

  if ownership-evidence:
    evidence-processes/List := ownership-evidence["processes"]
    evidence-processes.do: | entry/Map |
      group-id := entry["process-group-id"]
      process/Map := entry["process"]
      container-name := container-name-for-group decoded-runtime group-id
      component := process-component
          group-id
          process["id"]
          container-name
      add-native-resources allocations roots edges process component
      add-process-external-payloads memory allocations roots process component

  if scope and (scope.get "kind") == "process-group":
    selected/Map := scope["selected"]
    selected-processes/List := selected.get "processes" --if-absent=: []
    external-component := selected-processes.size == 1
        ? process-component
            selected["id"]
            selected-processes[0]["id"]
            container-name-for-group decoded-runtime selected["id"]
        : "toit-process-group:$(selected["id"])"
    add-external-payloads memory allocations roots external-component

  result := reconcile
      allocations
      roots
      edges
      --allocation-coverage-complete=allocator-complete
      --no-root-coverage-complete
  result["captured-region-bytes"] = captured-region-bytes
  result["allocation-tag-catalog"] = allocation-tag-accounting allocator
  result["allocator"] = allocator
  result["root-coverage"] = ownership-root-coverage
      scope
      ownership-evidence
      gc-metadata["state"]
      gc-spare-chunk["state"]
      event-sources["state"]
      freertos-tasks["state"]
      libc["state"]
      gpio["state"]
      platform-statics["state"]
  result["gc-metadata"] = gc-metadata
  result["gc-spare-chunk"] = gc-spare-chunk
  result["allocator-heap-backing"] = allocator-heaps
  result["scheduler-threads"] = scheduler-threads
  result["event-sources"] = event-sources
  result["libc"] = libc
  result["gpio"] = gpio
  result["platform-statics"] = platform-statics
  result["freertos-tasks"] = freertos-tasks
  result["physical-memory"] = physical-memory
  apply-physical-memory-coverage result physical-memory
  result["native-ownership"] = {
    "format": ownership["format"],
    "format-version": ownership["format-version"],
    "source": inspector-description ? "envelope-description" : "legacy-inspector-profile",
    "declared-decoders": ownership["decoders"],
    "unsupported-decoders": unsupported-decoders,
  }
  result["coverage"]["allocator-consistency"] = allocator["state"] == "complete"
      ? "stopped-image-structurally-validated"
      : "incomplete"
  result["coverage"]["physical-memory-regions"] = physical-memory["coverage"]
  if allocator["state"] == "complete":
    result["coverage"]["allocation-tags"] = "complete"
  else if allocator["state"] == "partial":
    result["coverage"]["allocator-blocks"] = "partial"
    result["coverage"]["allocation-tags"] = "partial"
  else if allocator["state"] == "unavailable":
    result["coverage"]["allocator-blocks"] = "not-enumerated"
    result["coverage"]["allocation-tags"] = "not-enumerated"
  result["scope"] = scope
      ? scope["kind"]
      : "full-device"
  if ownership-evidence:
    result["ownership-discovery"] = {
      "state": ownership-evidence["state"],
      "source": ownership-evidence["source"],
      "process-count": ownership-evidence["processes"].size,
      "unresolved": ownership-evidence["unresolved"],
    }
  result["diagnostics"].add-all diagnostics
  if scope:
    unresolved/List := scope.get "unresolved" --if-absent=: []
    result["unresolved"] = unresolved
    result["coverage"]["declared-root-layout-gaps"] = unresolved.size
  else if ownership-evidence:
    unresolved/List := ownership-evidence["unresolved"]
    result["unresolved"] = unresolved
    result["coverage"]["declared-root-layout-gaps"] = unresolved.size
  else:
    result["unresolved"] = []
    result["coverage"]["declared-root-layout-gaps"] = null
  return result

add-physical-memory-regions
    allocations/List roots/List allocator/Map ownership/Map
    -> Map:
  declarations/List := ownership.get "physical-memory-regions" --if-absent=: []
  if not (ownership-decoder-enabled ownership "physical-memory-regions") or
      declarations.is-empty:
    return {
      "state": "not-enumerated",
      "coverage": "not-enumerated",
      "declared-components": [],
      "owned-bytes": 0,
      "released-to-allocator-bytes": 0,
      "unknown-state-bytes": 0,
      "regions": [],
      "category-coverage": {:},
      "reason": "PHYSICAL_MEMORY_REGIONS_NOT_DECLARED",
    }

  regions := []
  components := {}
  category-coverage := {:}
  owned-bytes := 0
  released-bytes := 0
  unknown-bytes := 0
  declarations.do: | declaration/Map |
    start := format.parse-address declaration["start"]
    end := format.parse-address declaration["end"]
    if end <= start: throw "INVALID_PHYSICAL_MEMORY_REGION"
    size := end - start
    component/string := declaration["component"]
    components.add component
    component-coverage/Map := category-coverage.get component --init=: {
      "static-linked": "not-enumerated",
      "sdk-reserved": "not-enumerated",
    }
    component-coverage[declaration["kind"]] = "declared"
    region := declaration.copy
    region["size"] = size
    state := physical-region-state allocator start end
    region["state"] = state
    if state == "released-to-allocator":
      released-bytes += size
    else if state == "owned":
      owned-bytes += size
      modeled := add-semantic-allocation allocations {
        "id": "physical-region/$(declaration["id"])",
        "address": declaration["start"],
        "size": size,
        "kind": "physical-memory-region",
        "physical-region-kind": declaration["kind"],
        "accounting-category": declaration["kind"],
        "storage": declaration["storage"],
        "origin-component": component,
        "evidence": declaration["evidence"],
      }
      roots.add (ownership-root
          "$(modeled["id"])/physical-owner"
          component
          declaration["kind"]
          declaration["start"])
    else:
      unknown-bytes += size
    regions.add region

  declared-components := []
  components.do: declared-components.add it
  release-complete := allocator["state"] == "complete"
  return {
    "state": release-complete ? "decoded" : "partial",
    // Only explicitly declared components are covered. This must never imply
    // whole-firmware static/reserved-memory coverage.
    "coverage": "partial-declared-components",
    "release-detection": release-complete ? "complete" : "partial",
    "declared-components": declared-components,
    "owned-bytes": owned-bytes,
    "released-to-allocator-bytes": released-bytes,
    "unknown-state-bytes": unknown-bytes,
    "regions": regions,
    "category-coverage": category-coverage,
  }

apply-physical-memory-coverage accounting/Map physical-memory/Map -> none:
  category-coverage/Map := physical-memory.get
      "category-coverage"
      --if-absent=: {:}
  components/List := accounting.get "components" --if-absent=: []
  components.do: | component/Map |
    name/string := component["component"]
    coverage := category-coverage.get name
    if not coverage:
      component["static-linked-bytes"] = null
      component["sdk-reserved-bytes"] = null
      component["physical-region-coverage"] = "not-enumerated"
      continue.do
    component-coverage/Map := coverage
    if component-coverage["static-linked"] != "declared":
      component["static-linked-bytes"] = null
    if component-coverage["sdk-reserved"] != "declared":
      component["sdk-reserved-bytes"] = null
    component["physical-region-coverage"] = "partial-declared-categories"

physical-region-state allocator/Map start/int end/int -> string:
  heaps/List := allocator.get "heaps" --if-absent=: []
  heaps.do: | heap/Map |
    if not (heap.get "active" --if-absent=: false): continue.do
    heap-start := format.parse-address heap["start"]
    heap-end := format.parse-address heap["end"]
    if start >= heap-start and end <= heap-end:
      return "released-to-allocator"
  return allocator["state"] == "complete" ? "owned" : "unknown"

add-gc-metadata
    memory/target.Target allocations/List roots/List layout/Map
    -> Map:
  singleton/int? := null
  metadata/int? := null
  size/int? := null
  exception := catch:
    singleton = runtime.layout-symbol-address layout "toit::GcMetadata::singleton_"
    metadata = read-uint32
        memory
        singleton +
            (runtime.layout-field-offset layout "toit::GcMetadata" "metadata_")
    size = read-uint32
        memory
        singleton +
            (runtime.layout-field-offset layout "toit::GcMetadata" "metadata_size_")
  if exception:
    return {
      "state": "not-enumerated",
      "reason": "GC_METADATA_LAYOUT_NOT_AVAILABLE",
      "context": "$exception",
    }
  if not metadata or not size or size <= 0:
    return {
      "state": "partial",
      "reason": "GC_METADATA_EXTENT_NOT_AVAILABLE",
      "singleton": format.hex-address singleton,
    }
  modeled := add-semantic-allocation allocations {
    "id": "toit-gc/metadata",
    "address": format.hex-address metadata,
    "size": size,
    "kind": "gc-metadata",
    "storage": storage-for-address memory metadata size,
    "origin-component": "toit-gc",
    "evidence": "gc-metadata-singleton",
  }
  roots.add (ownership-root
      "$(modeled["id"])/gc-metadata-root"
      "toit-gc"
      "gc-metadata-singleton"
      (format.hex-address metadata))
  return {
    "state": "decoded",
    "singleton": format.hex-address singleton,
    "address": format.hex-address metadata,
    "size": size,
    "target-allocation-id": modeled["id"],
  }

add-gc-spare-chunk
    memory/target.Target allocations/List roots/List layout/Map
    -> Map:
  slot/int? := null
  chunk/int? := null
  start/int? := null
  end/int? := null
  exception := catch:
    slot = runtime.layout-symbol-address layout "toit::ObjectMemory::spare_chunk_"
    chunk = read-uint32 memory slot
    start = read-uint32
        memory
        chunk + (runtime.layout-field-offset layout "toit::Chunk" "start_")
    end = read-uint32
        memory
        chunk + (runtime.layout-field-offset layout "toit::Chunk" "end_")
  if exception:
    return {
      "state": "not-enumerated",
      "reason": "GC_SPARE_CHUNK_LAYOUT_NOT_AVAILABLE",
      "context": "$exception",
    }
  if not chunk or not start or not end or end <= start:
    return {
      "state": "partial",
      "reason": "GC_SPARE_CHUNK_EXTENT_NOT_AVAILABLE",
    }
  modeled := add-semantic-allocation allocations {
    "id": "toit-gc/spare-new-space",
    "address": format.hex-address start,
    "size": end - start,
    "kind": "gc-spare-new-space",
    "storage": storage-for-address memory start (end - start),
    "origin-component": "toit-gc",
    "chunk-address": format.hex-address chunk,
    "evidence": "object-memory-spare-chunk-singleton",
  }
  roots.add (ownership-root
      "$(modeled["id"])/spare-new-space-root"
      "toit-gc"
      "gc-spare-new-space"
      (format.hex-address start))
  return {
    "state": "decoded",
    "chunk": format.hex-address chunk,
    "address": format.hex-address start,
    "size": end - start,
    "target-allocation-id": modeled["id"],
  }

add-allocator-heap-backing allocations/List roots/List allocator/Map -> Map:
  if allocator["state"] == "unavailable":
    return {"state": "not-enumerated", "heap-count": 0, "root-count": 0}
  heaps/List := allocator.get "heaps" --if-absent=: []
  root-count := 0
  heaps.do: | heap/Map |
    descriptor := format.parse-address heap["descriptor"]
    add-address-root
        allocations
        roots
        "esp-idf-allocator"
        "registered-heap-descriptor"
        descriptor
        "registered-heaps-list"
    heap-address-value := heap.get "address"
    // Inactive registered heaps have a descriptor and range, but no allocator
    // control structure to own or traverse.
    if not heap-address-value is string: continue.do
    heap-address := format.parse-address heap-address-value
    add-address-root
        allocations
        roots
        "esp-idf-allocator"
        "allocator-control-structure"
        heap-address
        "registered-heap-descriptor"
    start := format.parse-address heap["start"]
    allocation := allocation-containing allocations start
    if not allocation: continue.do
    allocation-start := format.parse-address allocation["address"]
    // Some IDF heaps are backed by an allocation from another registered
    // heap. The registration is the current owner of that backing block.
    if allocation-start != start: continue.do
    semantic/List := allocation.get "semantic" --init=: []
    allocation["reserved-capacity"] = true
    allocation["reserved-capacity-bytes"] = allocation["size"]
    allocation["nested-heap-live-bytes"] = heap["allocated-bytes"]
    allocation["nested-heap-free-bytes"] = heap["free-bytes"]
    allocation["nested-heap-overhead-bytes"] = heap["overhead-bytes"]
    semantic.add {
      "id": "esp-idf-allocator/heap-backing/$(heap["index"])",
      "address": heap["start"],
      "size": allocation["size"],
      "kind": "allocator-heap-backing",
      "origin-component": "esp-idf-allocator",
      "descriptor": heap["descriptor"],
      "evidence": "registered-heap-range",
    }
    roots.add (ownership-root
        "esp-idf-allocator/heap-backing/$(heap["index"])/registered-root"
        "esp-idf-allocator"
        "registered-allocator-heap"
        heap["start"])
    root-count++
  return {
    "state": allocator["state"] == "complete" ? "decoded" : "partial",
    "heap-count": heaps.size,
    "root-count": root-count,
  }

add-scheduler-thread-roots
    memory/target.Target allocations/List roots/List layout/Map
    -> Map:
  threads := []
  exception := catch:
    vm-slot := runtime.layout-symbol-address layout "toit::VM::current_"
    vm := read-uint32 memory vm-slot
    scheduler := read-uint32
        memory
        vm + (runtime.layout-field-offset layout "toit::VM" "scheduler_")
    add-address-root
        allocations
        roots
        "toit-runtime"
        "scheduler"
        scheduler
        "vm-scheduler-field"
    count := read-uint32
        memory
        scheduler +
            (runtime.layout-field-offset layout "toit::Scheduler" "num_threads_")
    if count < 0 or count > 16: throw "INVALID_SCHEDULER_THREAD_COUNT"
    anchor := scheduler +
        (runtime.layout-field-offset layout "toit::Scheduler" "threads_")
    element-offset := runtime.layout-constant
        layout
        "toit::SchedulerThread::SCHEDULER_LIST_ELEMENT_OFFSET"
    next-offset := runtime.layout-field-offset
        layout
        "LinkedListElement<toit::SchedulerThread, 1>"
        "next_"
    element := read-uint32 memory (anchor + next-offset)
    count.repeat: | index |
      if element == 0: throw "SCHEDULER_THREAD_LIST_ENDED_EARLY"
      thread := element - element-offset
      component := "toit-scheduler-thread:$index"
      add-address-root allocations roots component "scheduler-thread" thread "scheduler-thread-list"
      thread-data := read-uint32
          memory
          thread + (runtime.layout-field-offset layout "toit::Thread" "handle_")
      add-address-root allocations roots component "thread-data" thread-data "thread-handle"
      tcb := read-uint32
          memory
          thread-data +
              (runtime.layout-field-offset layout "toit::ThreadData" "handle")
      add-address-root allocations roots component "freertos-tcb" tcb "task-handle"
      terminated := read-uint32
          memory
          thread-data +
              (runtime.layout-field-offset layout "toit::ThreadData" "terminated")
      add-address-root allocations roots component "termination-semaphore" terminated "thread-data"
      stack := read-uint32
          memory
          tcb +
              (runtime.layout-field-offset layout "struct tskTaskControlBlock" "pxStack")
      stack-end := read-uint32
          memory
          tcb +
              (runtime.layout-field-offset layout "struct tskTaskControlBlock" "pxEndOfStack")
      add-address-root allocations roots component "freertos-stack" stack "tcb-stack"
      add-newlib-task-roots memory allocations roots layout tcb component
      threads.add {
        "index": index,
        "component": component,
        "thread": format.hex-address thread,
        "thread-data": format.hex-address thread-data,
        "tcb": format.hex-address tcb,
        "stack": format.hex-address stack,
        "stack-end": format.hex-address stack-end,
        "stack-bytes": stack-end >= stack ? stack-end - stack + 1 : null,
      }
      element = read-uint32 memory (element + next-offset)
    if element != 0: throw "SCHEDULER_THREAD_LIST_LONGER_THAN_COUNT"
  if exception:
    return {
      "state": "partial",
      "reason": "SCHEDULER_THREAD_TRAVERSAL_FAILED",
      "context": "$exception",
      "threads": threads,
    }
  return {"state": "decoded-toit-threads", "threads": threads}

add-event-source-roots
    memory/target.Target allocations/List roots/List layout/Map ownership/Map
    -> Map:
  sources := []
  native-thread-tcbs := []
  exception := catch:
    vm-slot := runtime.layout-symbol-address layout "toit::VM::current_"
    vm := read-uint32 memory vm-slot
    manager := read-uint32
        memory
        vm + (runtime.layout-field-offset layout "toit::VM" "event_manager_")
    add-address-root
        allocations
        roots
        "toit-runtime"
        "event-source-manager"
        manager
        "vm-event-manager-field"
    anchor := manager +
        (runtime.layout-field-offset
            layout
            "toit::EventSourceManager"
            "event_sources_")
    element-offset := runtime.layout-constant
        layout
        "toit::EventSource::MANAGER_LIST_ELEMENT_OFFSET"
    next-offset := runtime.layout-field-offset
        layout
        "LinkedListElement<toit::EventSource, 1>"
        "next_"
    element := read-uint32 memory (anchor + next-offset)
    seen := {}
    while element != 0 and sources.size < 32:
      if seen.contains element: throw "EVENT_SOURCE_LIST_CYCLE"
      seen.add element
      source := element - element-offset
      vtable := read-uint32 memory source
      dynamic-type := scope-planner.dynamic-type-for-vtable layout vtable
      component := event-source-component dynamic-type
      add-address-root allocations roots component "event-source" source "event-source-manager-list"
      source-allocation := allocation-containing allocations source
      if source-allocation:
        semantic/List := source-allocation.get "semantic" --init=: []
        semantic.add {
          "id": "$component/event-source-object",
          "address": format.hex-address source,
          "size": 0,
          "kind": "event-source-object",
          "dynamic-type": dynamic-type,
          "origin-component": component,
          "evidence": "event-source-manager-list+elf-vtable",
        }
      mutex := read-uint32
          memory
          source +
              (runtime.layout-field-offset layout "toit::EventSource" "mutex_")
      add-mutex-roots memory allocations roots layout mutex component
      add-event-source-fields
          memory
          allocations
          roots
          layout
          ownership
          source
          dynamic-type
          component
      thread := add-event-source-thread-roots memory allocations roots layout source dynamic-type component
      if thread: native-thread-tcbs.add thread["tcb"]
      sources.add {
        "address": format.hex-address source,
        "dynamic-type": dynamic-type,
        "component": component,
        "mutex": format.hex-address mutex,
        "native-thread": thread,
      }
      element = read-uint32 memory (element + next-offset)
    if sources.size == 32: throw "EVENT_SOURCE_LIST_LIMIT"
    default-loop := add-default-event-loop-roots memory allocations roots layout "system-events"
    if default-loop: native-thread-tcbs.add default-loop["tcb"]
  if exception:
    return {
      "state": "partial",
      "reason": "EVENT_SOURCE_TRAVERSAL_FAILED",
      "context": "$exception",
      "sources": sources,
      "native-thread-tcbs": native-thread-tcbs,
    }
  return {
    "state": "decoded-declared-fields",
    "sources": sources,
    "native-thread-tcbs": native-thread-tcbs,
  }

add-default-event-loop-roots
    memory/target.MemoryReader
    allocations/List
    roots/List
    layout/Map
    component/string
    -> Map?:
  slot := runtime.layout-symbol-address layout "s_default_loop"
  loop := read-uint32 memory slot
  if loop == 0: return null
  add-address-root allocations roots component "esp-event-loop" loop "s_default_loop"
  queue := read-uint32
      memory
      loop +
          (runtime.layout-field-offset
              layout
              "struct esp_event_loop_instance"
              "queue")
  add-address-root allocations roots component "freertos-queue" queue "esp-event-loop.queue"
  semaphore := read-uint32
      memory
      loop +
          (runtime.layout-field-offset
              layout
              "struct esp_event_loop_instance"
              "mutex")
  add-address-root allocations roots component "event-loop-mutex" semaphore "esp-event-loop.mutex"
  tcb := read-uint32
      memory
      loop +
          (runtime.layout-field-offset
              layout
              "struct esp_event_loop_instance"
              "task")
  add-address-root allocations roots component "freertos-tcb" tcb "esp-event-loop.task"
  stack := read-uint32
      memory
      tcb +
          (runtime.layout-field-offset layout "struct tskTaskControlBlock" "pxStack")
  add-address-root allocations roots component "freertos-stack" stack "tcb-stack"
  add-newlib-task-roots memory allocations roots layout tcb component
  return {
    "address": format.hex-address loop,
    "queue": format.hex-address queue,
    "tcb": tcb,
    "tcb-address": format.hex-address tcb,
    "stack": format.hex-address stack,
  }

add-event-source-fields
    memory/target.Target
    allocations/List
    roots/List
    layout/Map
    ownership/Map
    source/int
    dynamic-type/string?
    component/string
    -> none:
  if not dynamic-type: return
  declarations/List := ownership.get
      "event-source-owned-fields"
      --if-absent=: []
  declaration/Map? := null
  declarations.do: | candidate/Map |
    candidate-type := candidate.get "dynamic-type"
    if candidate-type == dynamic-type: declaration = candidate
  if not declaration: return
  fields/List := declaration.get "fields" --if-absent=: []
  fields.do: | field/Map |
    add-owned-pointer-field
        memory
        allocations
        roots
        layout
        source
        dynamic-type
        field["name"]
        component
        field["kind"]

add-owned-pointer-field
    memory/target.MemoryReader
    allocations/List
    roots/List
    layout/Map
    owner/int
    type/string
    field/string
    component/string
    kind/string
    -> none:
  pointer := read-uint32
      memory
      owner + (runtime.layout-field-offset layout type field)
  add-address-root allocations roots component kind pointer "$type.$field"

add-mutex-roots
    memory/target.MemoryReader
    allocations/List
    roots/List
    layout/Map
    mutex/int
    component/string
    -> none:
  if mutex == 0: return
  add-address-root allocations roots component "mutex" mutex "event-source.mutex_"
  semaphore := read-uint32
      memory
      mutex + (runtime.layout-field-offset layout "toit::Mutex" "sem_")
  add-address-root allocations roots component "mutex-semaphore" semaphore "mutex.sem_"

add-event-source-thread-roots
    memory/target.MemoryReader
    allocations/List
    roots/List
    layout/Map
    source/int
    dynamic-type/string?
    component/string
    -> Map?:
  constant/string? := null
  if dynamic-type == "toit::TimerEventSource":
    constant = "toit::TimerEventSource::THREAD_OFFSET"
  else if dynamic-type == "toit::EventQueueEventSource":
    constant = "toit::EventQueueEventSource::THREAD_OFFSET"
  else if dynamic-type == "toit::TlsEventSource":
    constant = "toit::TlsEventSource::THREAD_OFFSET"
  if not constant: return null
  thread := source + (runtime.layout-constant layout constant)
  thread-data := read-uint32
      memory
      thread + (runtime.layout-field-offset layout "toit::Thread" "handle_")
  if thread-data == 0: return null
  add-address-root allocations roots component "thread-data" thread-data "event-source-thread"
  tcb := read-uint32
      memory
      thread-data + (runtime.layout-field-offset layout "toit::ThreadData" "handle")
  add-address-root allocations roots component "freertos-tcb" tcb "thread-data.handle"
  terminated := read-uint32
      memory
      thread-data +
          (runtime.layout-field-offset layout "toit::ThreadData" "terminated")
  add-address-root allocations roots component "termination-semaphore" terminated "thread-data.terminated"
  stack := read-uint32
      memory
      tcb +
          (runtime.layout-field-offset layout "struct tskTaskControlBlock" "pxStack")
  stack-end := read-uint32
      memory
      tcb +
          (runtime.layout-field-offset layout "struct tskTaskControlBlock" "pxEndOfStack")
  add-address-root allocations roots component "freertos-stack" stack "tcb-stack"
  add-newlib-task-roots memory allocations roots layout tcb component
  return {
    "thread-data": format.hex-address thread-data,
    "tcb": tcb,
    "tcb-address": format.hex-address tcb,
    "stack": format.hex-address stack,
    "stack-end": format.hex-address stack-end,
  }

event-source-component dynamic-type/string? -> string:
  if dynamic-type == "toit::TimerEventSource": return "timers"
  if dynamic-type == "toit::SystemEventSource": return "system-events"
  if dynamic-type == "toit::EventQueueEventSource": return "event-queue"
  if dynamic-type == "toit::LwipEventSource": return "networking"
  if dynamic-type == "toit::TlsEventSource": return "tls"
  if dynamic-type == "toit::BleEventSource": return "bluetooth"
  if dynamic-type and dynamic-type.contains "NopEventSource": return "toit-runtime"
  return dynamic-type or "unknown-event-source"

add-global-newlib-roots
    memory/target.MemoryReader allocations/List roots/List layout/Map
    -> Map:
  glue/int? := null
  count := 0
  exception := catch:
    glue = runtime.layout-symbol-address layout "__sglue"
    count = add-newlib-glue-chain memory allocations roots layout glue "libc"
    static-files := runtime.layout-symbol-address layout "__sf"
    add-newlib-file-roots
        memory
        allocations
        roots
        layout
        static-files
        3
        "libc"
        "static"
  if exception:
    return {
      "state": "partial",
      "reason": "NEWLIB_GLOBAL_GLUE_TRAVERSAL_FAILED",
      "context": "$exception",
    }
  return {
    "state": "decoded",
    "glue": format.hex-address glue,
    "dynamic-glue-count": count,
    "static-file-count": 3,
  }

add-gpio-static-roots
    memory/target.MemoryReader allocations/List roots/List layout/Map
    -> Map:
  pointers := []
  exception := catch:
    pool := runtime.layout-symbol-address layout "toit::gpio_pins"
    elements := read-uint32
        memory
        pool +
            (runtime.layout-constant layout "toit::gpio_pins::ELEMENTS_OFFSET")
    add-address-root allocations roots "gpio" "pin-resource-pool" elements "gpio_pins.elements_"
    pointers.add {
      "kind": "pin-resource-pool",
      "address": format.hex-address elements,
    }
    context := runtime.layout-symbol-address layout "gpio_context"
    handlers := read-uint32
        memory
        context +
            (runtime.layout-constant
                layout
                "esp-idf::gpio_context::ISR_FUNC_OFFSET")
    add-address-root allocations roots "gpio" "isr-handler-table" handlers "gpio_context.gpio_isr_func"
    pointers.add {
      "kind": "isr-handler-table",
      "address": format.hex-address handlers,
    }
  if exception:
    return {
      "state": "partial",
      "reason": "GPIO_STATIC_ROOT_TRAVERSAL_FAILED",
      "context": "$exception",
      "pointers": pointers,
    }
  return {"state": "decoded", "pointers": pointers}

add-platform-static-roots
    memory/target.MemoryReader allocations/List roots/List layout/Map ownership/Map
    -> Map:
  pointers := []
  diagnostics := []

  entropy-exception := catch:
    entropy := runtime.layout-symbol-address layout "toit::EntropyMixer::instance_"
    accumulator := entropy
        + (runtime.layout-field-offset layout "toit::EntropyMixer" "context_")
        + (runtime.layout-field-offset
            layout
            "mbedtls_entropy_context"
            "accumulator")
    digest := read-uint32
        memory
        accumulator +
            (runtime.layout-field-offset layout "mbedtls_md_context_t" "md_ctx")
    add-address-root allocations roots "crypto" "entropy-digest-state" digest
        "EntropyMixer.context_.accumulator.md_ctx"
    pointers.add {
      "kind": "entropy-digest-state",
      "address": format.hex-address digest,
    }
    hmac := read-uint32
        memory
        accumulator +
            (runtime.layout-field-offset layout "mbedtls_md_context_t" "hmac_ctx")
    if hmac != 0:
      add-address-root allocations roots "crypto" "entropy-hmac-state" hmac
          "EntropyMixer.context_.accumulator.hmac_ctx"
      pointers.add {
        "kind": "entropy-hmac-state",
        "address": format.hex-address hmac,
      }
    mutex := read-uint32
        memory
        entropy +
            (runtime.layout-field-offset layout "toit::EntropyMixer" "mutex_")
    add-address-root allocations roots "crypto" "entropy-mutex" mutex
        "EntropyMixer.mutex_"
    pointers.add {
      "kind": "entropy-mutex",
      "address": format.hex-address mutex,
    }
  if entropy-exception:
    diagnostics.add {
      "code": "ENTROPY_MIXER_ROOT_TRAVERSAL_FAILED",
      "context": "$entropy-exception",
    }

  toit-mutex-slots/List := ownership.get "toit-mutex-slots" --if-absent=: []
  toit-mutex-slots.do: | spec/Map |
    symbol/string := spec["symbol"]
    component/string := spec["component"]
    kind/string := spec["kind"]
    mutex-exception := catch:
      slot := runtime.layout-symbol-address layout symbol
      mutex := read-uint32 memory slot
      add-toit-mutex-root memory allocations roots layout mutex component kind symbol
      pointers.add {
        "kind": kind,
        "address": format.hex-address mutex,
      }
    if mutex-exception:
      diagnostics.add {
        "code": "TOIT_STATIC_MUTEX_ROOT_TRAVERSAL_FAILED",
        "symbol": symbol,
        "context": "$mutex-exception",
      }

  program-heap-exception := catch:
    program-heap := runtime.layout-symbol-address
        layout
        "toit::ProgramHeapMemory::instance_"
    mutex := read-uint32
        memory
        program-heap
            + (runtime.layout-field-offset
                layout
                "toit::ProgramHeapMemory"
                "memory_mutex_")
    add-toit-mutex-root
        memory
        allocations
        roots
        layout
        mutex
        "toit-program-heap"
        "program-heap-mutex"
        "ProgramHeapMemory.memory_mutex_"
    pointers.add {
      "kind": "program-heap-mutex",
      "address": format.hex-address mutex,
    }
  if program-heap-exception:
    diagnostics.add {
      "code": "PROGRAM_HEAP_MUTEX_ROOT_TRAVERSAL_FAILED",
      "context": "$program-heap-exception",
    }

  direct-static-roots/List := ownership.get
      "direct-static-roots"
      --if-absent=: []
  direct-static-roots.do: | spec/Map |
    symbol/string := spec["symbol"]
    component/string := spec["component"]
    kind/string := spec["kind"]
    root-exception := catch:
      slot := runtime.layout-symbol-address layout symbol
      address := read-uint32 memory slot
      add-address-root allocations roots component kind address symbol
      pointers.add {
        "kind": kind,
        "address": format.hex-address address,
      }
    if root-exception:
      diagnostics.add {
        "code": "STATIC_LIST_ROOT_TRAVERSAL_FAILED",
        "symbol": symbol,
        "context": "$root-exception",
      }

  resource-pools/List := ownership.get "resource-pools" --if-absent=: []
  resource-pools.do: | spec/Map |
    symbol/string := spec["symbol"]
    offset-name/string := spec["elements-offset"]
    component/string := spec["component"]
    kind/string := spec["kind"]
    pool-exception := catch:
      pool := runtime.layout-symbol-address layout symbol
      elements := read-uint32 memory (pool + (runtime.layout-constant layout offset-name))
      add-address-root allocations roots component kind elements "$(symbol).elements_"
      pointers.add {
        "kind": kind,
        "address": format.hex-address elements,
      }
    if pool-exception:
      diagnostics.add {
        "code": "RESOURCE_POOL_ROOT_TRAVERSAL_FAILED",
        "symbol": symbol,
        "context": "$pool-exception",
      }

  crypto-lock-exception := catch:
    lock-slot := runtime.layout-symbol-address layout "s_crypto_sha_aes_lock"
    lock := read-uint32 memory lock-slot
    add-address-root allocations roots "crypto" "sha-aes-lock" lock
        "s_crypto_sha_aes_lock"
    pointers.add {
      "kind": "sha-aes-lock",
      "address": format.hex-address lock,
    }
  if crypto-lock-exception:
    diagnostics.add {
      "code": "CRYPTO_LOCK_ROOT_TRAVERSAL_FAILED",
      "context": "$crypto-lock-exception",
    }

  gdma-exception := catch:
    platform := runtime.layout-constant layout "esp-idf::gdma::PLATFORM_ADDRESS"
    group := read-uint32
        memory
        platform + (runtime.layout-field-offset layout "gdma_platform_t" "groups")
    add-address-root allocations roots "dma" "gdma-group" group
        "gdma.c::s_platform.groups[0]"
    pointers.add {
      "kind": "gdma-group",
      "address": format.hex-address group,
    }
  if gdma-exception:
    diagnostics.add {
      "code": "GDMA_PLATFORM_ROOT_TRAVERSAL_FAILED",
      "context": "$gdma-exception",
    }

  tcpip-exception := catch:
    mailbox-slot := runtime.layout-symbol-address layout "tcpip_mbox"
    mailbox := read-uint32 memory mailbox-slot
    add-address-root allocations roots "networking" "tcpip-mailbox" mailbox
        "tcpip.c::tcpip_mbox"
    pointers.add {
      "kind": "tcpip-mailbox",
      "address": format.hex-address mailbox,
    }
    queue := read-uint32
        memory
        mailbox +
            (runtime.layout-field-offset layout "struct sys_mbox_s" "os_mbox")
    add-address-root allocations roots "networking" "tcpip-mailbox-queue" queue
        "tcpip_mbox.os_mbox"
    pointers.add {
      "kind": "tcpip-mailbox-queue",
      "address": format.hex-address queue,
    }
  if tcpip-exception:
    diagnostics.add {
      "code": "TCPIP_MAILBOX_ROOT_TRAVERSAL_FAILED",
      "context": "$tcpip-exception",
    }

  static-locks/List := ownership.get "static-locks" --if-absent=: []
  static-locks.do: | spec/Map |
    symbol/string := spec["symbol"]
    component/string := spec["component"]
    kind/string := spec["kind"]
    lock-exception := catch:
      slot := runtime.layout-symbol-address layout symbol
      lock := read-uint32 memory slot
      add-address-root allocations roots component kind lock symbol
      pointers.add {
        "kind": kind,
        "address": format.hex-address lock,
      }
    if lock-exception:
      diagnostics.add {
        "code": "STATIC_LOCK_ROOT_TRAVERSAL_FAILED",
        "symbol": symbol,
        "context": "$lock-exception",
      }

  constant-locks/List := ownership.get "constant-locks" --if-absent=: []
  constant-locks.do: | spec/Map |
    constant/string := spec["constant"]
    component/string := spec["component"]
    kind/string := spec["kind"]
    lock-exception := catch:
      slot := runtime.layout-constant layout constant
      lock := read-uint32 memory slot
      add-address-root allocations roots component kind lock constant
      pointers.add {
        "kind": kind,
        "address": format.hex-address lock,
      }
    if lock-exception:
      diagnostics.add {
        "code": "STATIC_LOCK_ROOT_TRAVERSAL_FAILED",
        "constant": constant,
        "context": "$lock-exception",
      }

  return {
    "state": diagnostics.is-empty ? "decoded" : "partial",
    "pointers": pointers,
    "diagnostics": diagnostics,
  }

add-toit-mutex-root
    memory/target.MemoryReader
    allocations/List
    roots/List
    layout/Map
    mutex/int
    component/string
    kind/string
    evidence/string
    -> none:
  if mutex == 0: return
  add-address-root allocations roots component kind mutex evidence
  semaphore := read-uint32
      memory
      mutex + (runtime.layout-field-offset layout "toit::Mutex" "sem_")
  add-address-root allocations roots component "$(kind)-semaphore" semaphore
      "$(evidence).sem_"

add-newlib-task-roots
    memory/target.MemoryReader
    allocations/List
    roots/List
    layout/Map
    tcb/int
    component/string
    -> int:
  types/Map := layout.get "types" --if-absent=: {:}
  if not (types.contains "struct _reent") or
      not (types.contains "struct _glue"):
    return 0
  reent := tcb +
      (runtime.layout-field-offset
          layout
          "struct tskTaskControlBlock"
          "xTLSBlock")
  glue := reent +
      (runtime.layout-field-offset layout "struct _reent" "_reserved_8")
  return add-newlib-glue-chain memory allocations roots layout glue component

add-newlib-glue-chain
    memory/target.MemoryReader
    allocations/List
    roots/List
    layout/Map
    embedded-glue/int
    component/string
    -> int:
  next-offset := runtime.layout-field-offset layout "struct _glue" "_next"
  count-offset := runtime.layout-field-offset layout "struct _glue" "_niobs"
  iobs-offset := runtime.layout-field-offset layout "struct _glue" "_iobs"
  glue := read-uint32 memory (embedded-glue + next-offset)
  seen := {}
  count := 0
  while glue != 0 and count < 32:
    if seen.contains glue: throw "NEWLIB_GLUE_LIST_CYCLE"
    seen.add glue
    add-address-root allocations roots component "newlib-stdio-glue" glue "_reent-glue-list"
    iobs := read-uint32 memory (glue + iobs-offset)
    add-address-root allocations roots component "newlib-file-table" iobs "_glue._iobs"
    file-count := read-uint32 memory (glue + count-offset)
    if file-count > 128: throw "INVALID_NEWLIB_FILE_COUNT"
    add-newlib-file-roots
        memory
        allocations
        roots
        layout
        iobs
        file-count
        component
        "$count"
    glue = read-uint32 memory (glue + next-offset)
    count++
  if count == 32: throw "NEWLIB_GLUE_LIST_LIMIT"
  return count

add-newlib-file-roots
    memory/target.MemoryReader
    allocations/List
    roots/List
    layout/Map
    files/int
    count/int
    component/string
    table-id/string
    -> none:
  types/Map := layout["types"]
  file-type/Map := types["struct __sFILE"]
  file-size/int := file-type["size"]
  buffer-base-offset := runtime.layout-field-offset layout "struct __sbuf" "_base"
  buffer-fields := ["_bf", "_ub", "_lb"]
  lock-offset := runtime.layout-field-offset layout "struct __sFILE" "_lock"
  count.repeat: | index |
    file := files + index * file-size
    buffer-fields.do: | field/string |
      buffer := read-uint32
          memory
          file
              + (runtime.layout-field-offset layout "struct __sFILE" field)
              + buffer-base-offset
      if buffer != 0:
        add-address-root
            allocations
            roots
            component
            "newlib-file-$(table-id)-$(index)-$(field)-buffer"
            buffer
            "__sFILE.$(field)._base"
    lock := read-uint32 memory (file + lock-offset)
    if lock != 0:
      add-address-root
          allocations
          roots
          component
          "newlib-file-$(table-id)-$(index)-lock"
          lock
          "__sFILE._lock"

add-freertos-task-roots
    memory/target.Target
    allocations/List
    roots/List
    layout/Map
    scheduler-threads/Map
    event-sources/Map
    -> Map:
  tasks := []
  tcbs := []
  seen := {}
  exception := catch:
    current-base := runtime.layout-symbol-address layout "pxCurrentTCBs"
    current-count := runtime.layout-constant layout "freertos::CURRENT_TCB_COUNT"
    current-count.repeat: | index |
      add-unique-address tcbs seen (read-uint32 memory (current-base + index * 4))

    list-type/Map := layout["types"]["struct xLIST"]
    list-size/int := list-type["size"]
    ready-base := runtime.layout-symbol-address layout "pxReadyTasksLists"
    ready-count := runtime.layout-constant layout "freertos::READY_LIST_COUNT"
    ready-count.repeat: | index |
      collect-freertos-list-tcbs memory layout (ready-base + index * list-size) tcbs seen

    ["xDelayedTaskList1", "xDelayedTaskList2", "xSuspendedTaskList",
        "xTasksWaitingTermination"].do: | symbol/string |
      collect-freertos-list-tcbs
          memory
          layout
          (runtime.layout-symbol-address layout symbol)
          tcbs
          seen

    pending-base := runtime.layout-symbol-address layout "xPendingReadyList"
    pending-count := runtime.layout-constant
        layout
        "freertos::PENDING_READY_LIST_COUNT"
    pending-count.repeat: | index |
      collect-freertos-list-tcbs memory layout (pending-base + index * list-size) tcbs seen

    toit-tcbs := {}
    scheduler-thread-list/List := scheduler-threads.get "threads" --if-absent=: []
    scheduler-thread-list.do: | thread/Map |
      toit-tcbs.add (format.parse-address thread["tcb"])
    event-source-tcbs/List := event-sources.get "native-thread-tcbs" --if-absent=: []
    event-source-tcbs.do: | tcb/int | toit-tcbs.add tcb

    name-offset := runtime.layout-field-offset
        layout
        "struct tskTaskControlBlock"
        "pcTaskName"
    stack-offset := runtime.layout-field-offset
        layout
        "struct tskTaskControlBlock"
        "pxStack"
    stack-end-offset := runtime.layout-field-offset
        layout
        "struct tskTaskControlBlock"
        "pxEndOfStack"
    tcbs.do: | tcb/int |
      if toit-tcbs.contains tcb: continue.do
      name := read-fixed-c-string memory (tcb + name-offset) 16
      if name.is-empty: name = "unnamed"
      component := "freertos-task:$name@$(format.hex-address tcb)"
      add-address-root allocations roots component "freertos-tcb" tcb "freertos-task-list"
      stack := read-uint32 memory (tcb + stack-offset)
      stack-end := read-uint32 memory (tcb + stack-end-offset)
      add-address-root allocations roots component "freertos-stack" stack "tcb-stack"
      add-newlib-task-roots memory allocations roots layout tcb component
      tasks.add {
        "component": component,
        "name": name,
        "tcb": format.hex-address tcb,
        "stack": format.hex-address stack,
        "stack-end": format.hex-address stack-end,
        "stack-bytes": stack-end >= stack ? stack-end - stack + 1 : null,
      }
  if exception:
    return {
      "state": "partial",
      "reason": "FREERTOS_TASK_TRAVERSAL_FAILED",
      "context": "$exception",
      "tasks": tasks,
    }
  return {"state": "decoded-freertos-tasks", "tasks": tasks}

collect-freertos-list-tcbs
    memory/target.MemoryReader layout/Map list/int tcbs/List seen/Set
    -> none:
  count := read-uint32
      memory
      list +
          (runtime.layout-field-offset layout "struct xLIST" "uxNumberOfItems")
  if count < 0 or count > 256: throw "INVALID_FREERTOS_LIST_COUNT"
  end := list + (runtime.layout-field-offset layout "struct xLIST" "xListEnd")
  item := read-uint32
      memory
      end +
          (runtime.layout-field-offset layout "struct xMINI_LIST_ITEM" "pxNext")
  next-offset := runtime.layout-field-offset layout "struct xLIST_ITEM" "pxNext"
  owner-offset := runtime.layout-field-offset layout "struct xLIST_ITEM" "pvOwner"
  count.repeat:
    if item == end: throw "FREERTOS_LIST_ENDED_EARLY"
    add-unique-address tcbs seen (read-uint32 memory (item + owner-offset))
    item = read-uint32 memory (item + next-offset)
  if item != end: throw "FREERTOS_LIST_LONGER_THAN_COUNT"

add-unique-address addresses/List seen/Set address/int -> none:
  if address == 0 or seen.contains address: return
  seen.add address
  addresses.add address

read-fixed-c-string memory/target.MemoryReader address/int size/int -> string:
  bytes := memory.read address size
  end := 0
  while end < bytes.size and bytes[end] != 0: end++
  return bytes[..end].to-string

add-address-root
    allocations/List roots/List component/string kind/string address/int evidence/string
    -> none:
  if address == 0: return
  allocation := allocation-containing allocations address
  if not allocation: return
  semantic/List := allocation.get "semantic" --init=: []
  semantic.add {
    "id": "$component/$kind",
    "address": format.hex-address address,
    "size": 0,
    "kind": kind,
    "origin-component": component,
    "evidence": evidence,
  }
  roots.add (ownership-root
      "$component/$kind/root"
      component
      kind
      (format.hex-address address))

read-uint32 memory/target.MemoryReader address/int -> int:
  return LITTLE-ENDIAN.uint32 (memory.read address 4) 0

discover-full-device-ownership
    memory/target.Target decoded-runtime/Map runtime-layout/Map
    -> Map:
  processes := []
  unresolved := []
  state := "complete"
  groups/List := decoded-runtime.get "process-groups" --if-absent=: []
  groups.do: | group/Map |
    group-id := group.get "id"
    if not group-id is int:
      state = "partial"
      unresolved.add {
        "kind": "full-device-ownership-discovery",
        "reason": "PROCESS_GROUP_ID_NOT_AVAILABLE",
      }
      continue.do
    plan/Map? := null
    exception := catch:
      plan = scope-planner.plan-process-group memory runtime-layout group-id
    if exception:
      state = "partial"
      unresolved.add {
        "kind": "full-device-ownership-discovery",
        "process-group-id": group-id,
        "reason": "OWNERSHIP_TRAVERSAL_FAILED",
        "context": "$exception",
      }
      continue.do
    planned-scope/Map := plan["capture-scope"]
    selected/Map := planned-scope["selected"]
    selected-processes/List := selected.get "processes" --if-absent=: []
    selected-processes.do: | process/Map |
      processes.add {
        "process-group-id": group-id,
        "process": process,
      }
    planned-unresolved/List := planned-scope.get "unresolved" --if-absent=: []
    if not planned-unresolved.is-empty: state = "partial"
    planned-unresolved.do: | entry/Map |
      item := entry.copy
      item["process-group-id"] = group-id
      unresolved.add item
  return {
    "state": state,
    "source": "stopped-full-device-traversal",
    "processes": processes,
    "unresolved": unresolved,
  }

/**
Reconciles allocation intervals with typed roots and ownership edges.

Only `strong` roots and `owns` or `contains` edges retain allocations. Weak and
  borrowed references remain evidence but do not establish liveness.
*/
reconcile
    allocations/List
    roots/List
    edges/List
    --allocation-coverage-complete/bool=false
    --root-coverage-complete/bool=false
    -> Map:
  validate-allocations allocations
  by-id := {:}
  owners := {:}
  allocations.do: | allocation/Map |
    id/string := allocation["id"]
    by-id[id] = allocation
    owners[id] = {}

  diagnostics := []
  resolved-roots := roots.map: | root/Map |
    result := root.copy
    target := format.parse-address root["target"]
    allocation := allocation-containing allocations target
    if allocation:
      result["target-allocation-id"] = allocation["id"]
    else:
      result["diagnostic"] = "ROOT_TARGET_NOT_MODELED"
      diagnostics.add {
        "code": "ROOT_TARGET_NOT_MODELED",
        "root-id": root["id"],
        "target": root["target"],
      }
    result

  resolved-edges := edges.map: | edge/Map |
    result := edge.copy
    target := format.parse-address edge["target"]
    allocation := allocation-containing allocations target
    if allocation:
      result["target-allocation-id"] = allocation["id"]
    else:
      result["diagnostic"] = "EDGE_TARGET_NOT_MODELED"
    result

  queue := []
  resolved-roots.do: | root/Map |
    strength/string := root.get "strength" --if-absent=: "strong"
    if not (retains strength): continue.do
    target-id := root.get "target-allocation-id"
    if not target-id: continue.do
    add-owner owners queue target-id root["component"]

  by-source := {:}
  resolved-edges.do: | edge/Map |
    (by-source.get edge["from-allocation-id"] --init=: []).add edge
  cursor := 0
  while cursor < queue.size:
    work/Map := queue[cursor++]
    outgoing/List := by-source.get work["allocation-id"] --if-absent=: []
    outgoing.do: | edge/Map |
      strength/string := edge.get "strength" --if-absent=: edge["kind"]
      if not (retains strength):
        continue.do
      target-id := edge.get "target-allocation-id"
      if target-id: add-owner owners queue target-id work["component"]

  modeled-bytes := 0
  modeled-reachable-bytes := 0
  modeled-unreachable-bytes := 0
  owned-bytes := 0
  shared-bytes := 0
  leak-candidate-bytes := 0
  items := allocations.map: | allocation/Map |
    result := allocation.copy
    size/int := allocation["size"]
    modeled-bytes += size
    allocation-owners/Set := owners[allocation["id"]]
    owner-list := []
    allocation-owners.do: owner-list.add it
    result["owners"] = owner-list
    result["reachable"] = not owner-list.is-empty
    if owner-list.size == 1:
      result["state"] = "owned"
      owned-bytes += size
      modeled-reachable-bytes += size
    else if owner-list.size > 1:
      result["state"] = "shared"
      shared-bytes += size
      modeled-reachable-bytes += size
    else:
      modeled-unreachable-bytes += size
      if allocation-coverage-complete and root-coverage-complete:
        result["state"] = "leak-candidate"
        leak-candidate-bytes += size
      else:
        result["state"] = "unexplained"
    result

  coverage-complete := allocation-coverage-complete and root-coverage-complete
  summary := {
    "modeled-allocation-count": items.size,
    "modeled-bytes": modeled-bytes,
    "modeled-reachable-bytes": modeled-reachable-bytes,
    "modeled-unreachable-bytes": modeled-unreachable-bytes,
    "owned-bytes": owned-bytes,
    "shared-bytes": shared-bytes,
    "leak-candidate-bytes": coverage-complete
        ? leak-candidate-bytes
        : null,
    "confirmed-leak-bytes": null,
  }
  return {
    "state": coverage-complete ? "complete" : "partial",
    "summary": summary,
    "coverage": {
      "allocator-blocks": allocation-coverage-complete
          ? "complete"
          : "not-enumerated",
      "root-set": root-coverage-complete
          ? "complete"
          : "partial",
      "leak-classification": coverage-complete
          ? "candidate-only"
          : "not-authoritative",
      "allocation-tags": allocation-coverage-complete
          ? "enumerated"
          : "defined-not-enumerated",
    },
    "components": component-summaries items,
    "storage": storage-summaries items,
    "allocations": items,
    "roots": resolved-roots,
    "edges": resolved-edges,
    "diagnostics": diagnostics,
  }

add-program-heap allocations/List roots/List heap/Map component/string -> none:
  program-heap := heap.get "program-heap"
  if not program-heap: return
  address/string := program-heap["address"]
  id := "$component/program-heap"
  modeled := add-semantic-allocation allocations {
    "id": id,
    "address": address,
    "size": program-heap["size"],
    "kind": "program-heap",
    "storage": "flash",
    "origin-component": component,
    "evidence": "runtime-program-heap",
  }
  roots.add (ownership-root
      "$(modeled["id"])/program-root"
      component
      "program"
      address)

add-space
    allocations/List roots/List heap/Map name/string component/string
    -> none:
  space := heap.get name
  if not space: return
  chunks/List := space.get "chunks" --if-absent=: []
  chunks.size.repeat: | index |
    chunk/Map := chunks[index]
    start/string := chunk["start"]
    end := format.parse-address chunk["end"]
    size := end - (format.parse-address start)
    id := "$component/$name/$index"
    modeled := add-semantic-allocation allocations {
      "id": id,
      "address": start,
      "size": size,
      "kind": "toit-heap-chunk",
      "space": name,
      "storage": "ram",
      "origin-component": "toit-runtime",
      "evidence": "runtime-heap-chunk",
      "census": chunk.get "census",
    }
    roots.add (ownership-root
        "$(modeled["id"])/$(name)-root"
        component
        "process-heap"
        start)

add-external-payloads
    memory/target.Target allocations/List roots/List component/string
    -> none:
  memory.regions.do: | region/target.MemoryRegion |
    if region.kind != "external-payload": continue.do
    id := "$component/external-payload/$(region.id)"
    modeled := add-semantic-allocation allocations {
      "id": id,
      "address": format.hex-address region.address,
      "size": region.size,
      "kind": "external-payload",
      "storage": storage-for-region region,
      "origin-component": component,
      "evidence": "selective-capture-external-payload",
    }
    roots.add (ownership-root
        "$(modeled["id"])/external-payload-root"
        component
        "toit-external-payload"
        (format.hex-address region.address))

add-process-external-payloads
    memory/target.Target allocations/List roots/List process/Map component/string
    -> none:
  references/List := process.get "external-payload-references" --if-absent=: []
  seen := {}
  references.do: | reference/Map |
    process-accounted := reference.get "process-accounted"
    if process-accounted == null:
      process-accounted = not reference.get "owner"
    if not process-accounted: continue.do
    address/string := reference["address"]
    size/int := reference["bytes"]
    if size <= 0: continue.do
    key := "$address:$size"
    if seen.contains key: continue.do
    seen.add key
    payload-kind := reference.get "payload-kind" --if-absent=: "external-payload"
    modeled := add-semantic-allocation allocations {
      "id": "$component/external-payload/$address/$size",
      "address": address,
      "size": size,
      "kind": payload-kind,
      "storage": storage-for-address memory (format.parse-address address) size,
      "origin-component": component,
      "source-object-address": reference.get "object-address",
      "evidence": "heap-object-external-payload-reference",
    }
    root := ownership-root
        "$(modeled["id"])/external-payload-root/$address"
        component
        "toit-external-payload"
        address
    root["source-object-address"] = reference.get "object-address"
    root["payload-kind"] = payload-kind
    root["payload-bytes"] = size
    roots.add root

add-native-resources
    allocations/List roots/List edges/List process/Map process-component/string
    -> none:
  groups/List := process.get "resource-groups" --if-absent=: []
  groups.size.repeat: | group-index |
    group/Map := groups[group-index]
    component := component-for-dynamic-type
        group.get "dynamic-type" --if-absent=: "native-resource"
    simple-group := (group.get "dynamic-type" --if-absent=: "").contains
        "SimpleResourceGroup"
    group-id := "$process-component/resource-group/$group-index"
    modeled-group := add-semantic-allocation allocations {
      "id": group-id,
      "address": group["address"],
      "size": group["captured-bytes"],
      "kind": "native-resource-group",
      "origin-component": component,
      "dynamic-type": group["dynamic-type"],
      "evidence": "elf-dynamic-type+captured-memory",
    }
    roots.add (ownership-root
        "$(modeled-group["id"])/resource-group-root"
        component
        "process-resource-group"
        group["address"])
    resources/List := group.get "resources" --if-absent=: []
    resources.size.repeat: | resource-index |
      resource/Map := resources[resource-index]
      resource-component := simple-group
          ? component-for-dynamic-type
              (resource.get "dynamic-type" --if-absent=: "native-resource")
          : component
      resource-id := "$group-id/resource/$resource-index"
      modeled-resource := add-semantic-allocation allocations {
        "id": resource-id,
        "address": resource["address"],
        "size": resource["captured-bytes"],
        "kind": "native-resource",
        "origin-component": resource-component,
        "dynamic-type": resource["dynamic-type"],
        "state-value": resource["state"],
        "fields": resource.get "fields" --if-absent=: {:},
        "evidence": "elf-dynamic-type+captured-memory",
      }
      if simple-group:
        roots.add (ownership-root
            "$(modeled-resource["id"])/native-resource-root"
            resource-component
            "simple-native-resource"
            resource["address"])
        edges.add {
          "from-allocation-id": modeled-group["id"],
          "target": resource["address"],
          "kind": "membership",
          "strength": "borrowed",
          "label": "resource",
        }
      else:
        edges.add {
          "from-allocation-id": modeled-group["id"],
          "target": resource["address"],
          "kind": "owns",
          "strength": "strong",
          "label": "resource",
        }

ownership-root id/string component/string kind/string target/string -> Map:
  return {
    "id": id,
    "component": component,
    "kind": kind,
    "strength": "strong",
    "target": target,
  }

component-for-dynamic-type dynamic-type/string -> string:
  if dynamic-type.contains "Ble" or dynamic-type.contains "BLE" or
      dynamic-type.contains "Bluetooth":
    return "bluetooth"
  if dynamic-type.contains "Wifi" or dynamic-type.contains "WiFi": return "wifi"
  if dynamic-type.contains "Tcp" or dynamic-type.contains "Udp" or
      dynamic-type.contains "Lwip":
    return "networking"
  if dynamic-type.contains "Timer": return "timers"
  result := dynamic-type
  if result.starts-with "toit::": result = result[6..]
  if result.ends-with "ResourceGroup":
    result = result[..result.size - "ResourceGroup".size]
  else if result.ends-with "Resource":
    result = result[..result.size - "Resource".size]
  return result.is-empty ? "native-runtime" : result

process-component
    group-id/any process-id/any container-name/string?=null
    -> string:
  if container-name:
    return "toit-container:$container-name/process:$group-id/$process-id"
  return "toit-process:$group-id/$process-id"

process-group-container-name group/Map -> string?:
  container/Map? := group.get "container"
  if not container: return null
  name := container.get "name"
  return name is string ? name : null

container-name-for-group decoded-runtime/Map group-id/any -> string?:
  groups/List := decoded-runtime.get "process-groups" --if-absent=: []
  groups.do: | group/Map |
    if (group.get "id") == group-id: return process-group-container-name group
  return null

storage-for-region region/target.MemoryRegion -> string:
  if region.kind == "external-ram" or region.kind == "psram":
    return "external-ram"
  if region.kind == "flash-mapped-data" or region.kind == "program-heap":
    return "flash"
  return "ram"

storage-for-address
    memory/target.Target address/int size/int
    -> string:
  memory.regions.do: | region/target.MemoryRegion |
    if address >= region.address and address + size <= region.end-address:
      return storage-for-region region
  return "unknown"

retains strength/string -> bool:
  return strength == "strong" or strength == "owns" or strength == "contains"

add-owner owners/Map queue/List allocation-id/string component/string -> none:
  allocation-owners/Set := owners[allocation-id]
  if allocation-owners.contains component: return
  allocation-owners.add component
  queue.add {
    "allocation-id": allocation-id,
    "component": component,
  }

allocation-containing allocations/List address/int -> Map?:
  allocations.do: | allocation/Map |
    start := format.parse-address allocation["address"]
    if address >= start and address < start + allocation["size"]:
      return allocation
  return null

validate-allocations allocations/List -> none:
  ids := {}
  allocations.do: | allocation/Map |
    id/string := allocation["id"]
    if ids.contains id: throw "DUPLICATE_ALLOCATION_ID"
    ids.add id
    if allocation["size"] <= 0: throw "INVALID_ALLOCATION_SIZE"

add-semantic-allocation allocations/List semantic/Map -> Map:
  address := format.parse-address semantic["address"]
  existing := allocation-containing allocations address
  if existing:
    start := format.parse-address existing["address"]
    if address + semantic["size"] <= start + existing["size"]:
      annotations/List := existing.get "semantic" --init=: []
      annotations.add semantic
      return existing
  allocations.add semantic
  return semantic

component-summaries allocations/List -> List:
  summaries := {:}
  allocations.do: | allocation/Map |
    owners/List := allocation["owners"]
    owners.do: | owner/string |
      entry/Map := summaries.get owner --init=: {
        "component": owner,
        "exclusive-bytes": 0,
        "shared-bytes": 0,
        "dynamic-and-runtime-bytes": 0,
        "static-linked-bytes": 0,
        "sdk-reserved-bytes": 0,
        "reserved-capacity-bytes": 0,
        "live-bytes-inside-reserves": 0,
        "allocation-count": 0,
      }
      if owners.size == 1:
        entry["exclusive-bytes"] += allocation["size"]
        category/string := allocation.get
            "accounting-category"
            --if-absent=: "dynamic-and-runtime"
        if category == "static-linked":
          entry["static-linked-bytes"] += allocation["size"]
        else if category == "sdk-reserved":
          entry["sdk-reserved-bytes"] += allocation["size"]
        else:
          entry["dynamic-and-runtime-bytes"] += allocation["size"]
      else:
        entry["shared-bytes"] += allocation["size"]
      entry["reserved-capacity-bytes"] +=
          allocation.get "reserved-capacity-bytes" --if-absent=: 0
      entry["live-bytes-inside-reserves"] +=
          allocation.get "nested-heap-live-bytes" --if-absent=: 0
      entry["allocation-count"] += 1
  result := []
  summaries.values.do: result.add it
  return result

storage-summaries allocations/List -> List:
  summaries := {:}
  allocations.do: | allocation/Map |
    storage/string := allocation.get "storage" --if-absent=: "unknown"
    entry/Map := summaries.get storage --init=: {
      "storage": storage,
      "bytes": 0,
      "allocation-count": 0,
    }
    entry["bytes"] += allocation["size"]
    entry["allocation-count"] += 1
  result := []
  summaries.values.do: result.add it
  return result

/** Allocator tags present in ESP32 firmware, whether or not this dump decoded them. */
allocation-tag-catalog -> List:
  return [
    allocation-tag 0 "misc" "native-runtime",
    allocation-tag 1 "external-byte-array" "toit-external-objects",
    allocation-tag 2 "tls/bignum" "crypto",
    allocation-tag 3 "external-string" "toit-external-objects",
    allocation-tag 4 "toit-processes" "toit-runtime",
    allocation-tag 5 "gc-metadata" "toit-gc",
    allocation-tag 6 "free" "allocator-free",
    allocation-tag 7 "lwip" "networking",
    allocation-tag 8 "heap-overhead" "allocator-overhead",
    allocation-tag 9 "unknown" "unknown",
    allocation-tag 10 "event-source" "event-sources",
    allocation-tag 11 "thread/other" "threads",
    allocation-tag 12 "thread/spawn" "threads",
    allocation-tag 13 "untagged" "untagged",
    allocation-tag 14 "wifi" "wifi",
    allocation-tag 15 "bluetooth" "bluetooth",
  ]

allocation-tag-accounting allocator/Map -> List:
  catalog := allocation-tag-catalog
  state/string := allocator["state"]
  if state == "unavailable":
    catalog.do: | tag/Map |
      tag["bytes"] = null
      tag["allocation-count"] = null
      tag["coverage"] = "not-enumerated"
    return catalog
  complete := state == "complete"
  catalog.do: | tag/Map |
    tag["bytes"] = 0
    tag["allocation-count"] = 0
    tag["coverage"] = complete ? "complete" : "partial"
  by-id := {:}
  catalog.do: | tag/Map | by-id[tag["id"]] = tag
  allocator["allocations"].do: | allocation/Map |
    decoded-tag-value := allocation.get "allocator-tag"
    // Semantic regions discovered after allocator decoding share this list,
    // but they are not compact-allocator allocations and have no native tag.
    if not decoded-tag-value is Map: continue.do
    decoded-tag/Map := decoded-tag-value
    id := decoded-tag.get "id"
    if id == null: id = 9
    entry/Map := by-id[id]
    entry["bytes"] += allocation["size"]
    entry["allocation-count"] += 1
  summary := allocator.get "summary"
  if summary:
    by-id[6]["bytes"] = summary["free-bytes"]
    by-id[6]["allocation-count"] = null
    by-id[8]["bytes"] = summary["overhead-bytes"]
    by-id[8]["allocation-count"] = null
  return catalog

allocation-tag id/int name/string component/string -> Map:
  return {
    "id": id,
    "name": name,
    "component": component,
  }

ownership-root-coverage
    scope/Map?
    evidence/Map?=null
    gc-metadata-state/string="not-enumerated"
    gc-spare-chunk-state/string="not-enumerated"
    event-sources-state/string="not-enumerated"
    freertos-tasks-state/string="not-enumerated"
    libc-state/string="not-enumerated"
    gpio-state/string="not-enumerated"
    platform-statics-state/string="not-enumerated"
    -> List:
  selective := scope and (scope.get "kind") == "process-group"
  unresolved/List := evidence
      ? evidence.get "unresolved" --if-absent=: []
      : []
  native-unresolved := unresolved.filter: | entry/Map |
    kind/string := entry.get "kind" --if-absent=: ""
    kind.contains "native" or
        kind == "full-device-ownership-discovery" or
        kind == "process-group-owned-native-memory"
  external-unresolved := unresolved.filter: | entry/Map |
    kind/string := entry.get "kind" --if-absent=: ""
    kind.contains "external" or
        kind == "full-device-ownership-discovery"
  evidence-available := evidence != null
  external-state := not evidence-available
      ? "not-enumerated"
      : (external-unresolved.is-empty
          ? (selective ? "decoded-captured-payloads" : "decoded")
          : "partial")
  declared-state := not evidence-available
      ? "not-enumerated"
      : (native-unresolved.is-empty ? "decoded-declared-layouts" : "partial")
  return [{
    "category": "toit-process-heaps",
    "state": "decoded",
    "retention": "strong",
  }, {
    "category": "toit-program-heaps",
    "state": "decoded",
    "retention": "strong",
  }, {
    "category": "toit-gc-metadata",
    "state": gc-metadata-state,
    "retention": "strong-singleton",
  }, {
    "category": "toit-gc-spare-new-space",
    "state": gc-spare-chunk-state,
    "retention": "strong-singleton",
  }, {
    "category": "toit-external-payloads",
    "state": external-state,
    "retention": "strong",
    "unresolved-count": external-unresolved.size,
  }, {
    "category": "native-resource-groups-and-resources",
    "state": declared-state,
    "retention": "strong-or-borrowed-by-declared-layout",
    "unresolved-count": native-unresolved.size,
  }, {
    "category": "runtime-event-source-singletons",
    "state": event-sources-state,
    "retention": "strong-event-manager-list-and-declared-fields",
  }, {
    "category": "rtos-and-idf-subsystem-roots",
    "state": freertos-tasks-state,
    "retention": "strong-task-list-roots",
  }, {
    "category": "newlib-stdio-roots",
    "state": libc-state,
    "retention": "strong-declared-glue-file-buffer-and-lock-fields",
  }, {
    "category": "gpio-static-roots",
    "state": gpio-state,
    "retention": "strong-declared-static-fields",
  }, {
    "category": "peripheral-and-dma-ownership",
    "state": platform-statics-state,
    "retention": "strong-declared-static-fields",
  }, {
    "category": "arbitrary-stop-register-owned-native-state",
    "state": "not-enumerated",
    "retention": "unknown",
  }]
