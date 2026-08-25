// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import io show LITTLE-ENDIAN

import .format as format
import .runtime as runtime
import .target as target

MAX-OWNERSHIP-LIST ::= 1_024
MAX-HEAP-OBJECTS ::= 1_048_576

plan-process-group reader/target.MemoryReader layout/Map group-id/int -> Map:
  runtime.validate-runtime-layout layout
  included := []
  unresolved := []
  omitted-group-ids := []
  region-inputs := []
  program-heaps := []

  vm-slot := runtime.layout-symbol-address layout "toit::VM::current_"
  include-range included region-inputs vm-slot 4 "vm-current-slot" "runtime-bootstrap" "rw"
  vm := read-pointer reader vm-slot
  if not vm: throw "VM_NOT_AVAILABLE"
  include-typed-range included region-inputs layout vm "toit::VM" "vm" "runtime-bootstrap"

  scheduler := read-pointer
      reader
      vm + (runtime.layout-field-offset layout "toit::VM" "scheduler_")
  if not scheduler: throw "SCHEDULER_NOT_AVAILABLE"
  include-typed-range
      included
      region-inputs
      layout
      scheduler
      "toit::Scheduler"
      "scheduler"
      "runtime-bootstrap"

  groups-offset := runtime.layout-field-offset layout "toit::Scheduler" "groups_"
  group-next-offset := runtime.layout-field-offset
      layout
      "DoubleLinkedListElement<toit::ProcessGroup, 1>"
      "next_"
  group-anchor := scheduler + groups-offset
  next-group := read-pointer reader (group-anchor + group-next-offset)
  seen-groups := {}
  selected-group/Map? := null
  group-count := 0
  while next-group and next-group != group-anchor and group-count < MAX-OWNERSHIP-LIST:
    if seen-groups.contains next-group: throw "PROCESS_GROUP_LIST_CYCLE"
    seen-groups.add next-group
    include-typed-range
        included
        region-inputs
        layout
        next-group
        "toit::ProcessGroup"
        "process-group-metadata"
        "runtime-bootstrap"
    current-id := read-int32
        reader
        next-group + (runtime.layout-field-offset layout "toit::ProcessGroup" "id_")
    catalog-program-heaps
        reader
        layout
        next-group
        current-id
        included
        region-inputs
        program-heaps
    if current-id == group-id:
      if selected-group: throw "DUPLICATE_PROCESS_GROUP_ID"
      selected-group = {
        "id": current-id,
        "address": format.hex-address next-group,
      }
    else:
      omitted-group-ids.add current-id
    next-group = read-pointer reader (next-group + group-next-offset)
    group-count++
  if group-count == MAX-OWNERSHIP-LIST: throw "PROCESS_GROUP_LIST_LIMIT"
  if not selected-group: throw "PROCESS_GROUP_NOT_FOUND"

  selected-address := format.parse-address selected-group["address"]
  group-program := read-pointer
      reader
      selected-address + (runtime.layout-field-offset layout "toit::ProcessGroup" "program_")
  selected-group["program"] = pointer-address group-program
  group-memory := read-pointer
      reader
      selected-address + (runtime.layout-field-offset layout "toit::ProcessGroup" "memory_")
  if group-memory:
    unresolved.add {
      "kind": "process-group-owned-native-memory",
      "address": format.hex-address group-memory,
      "reason": "SIZE_NOT_RECORDED",
    }

  processes := []
  process-next-offset := runtime.layout-field-offset
      layout
      "LinkedListElement<toit::Process, 1>"
      "next_"
  process-anchor := selected-address +
      (runtime.layout-field-offset layout "toit::ProcessGroup" "processes_")
  next-process := read-pointer reader (process-anchor + process-next-offset)
  seen-processes := {}
  process-count := 0
  while next-process and process-count < MAX-OWNERSHIP-LIST:
    if seen-processes.contains next-process: throw "PROCESS_LIST_CYCLE"
    seen-processes.add next-process
    include-typed-range
        included
        region-inputs
        layout
        next-process
        "toit::Process"
        "selected-process-metadata"
        "runtime-bootstrap"
    process := plan-process
        reader
        layout
        next-process
        included
        region-inputs
        unresolved
        program-heaps
    processes.add process
    next-process = read-pointer reader (next-process + process-next-offset)
    process-count++
  if process-count == MAX-OWNERSHIP-LIST: throw "PROCESS_LIST_LIMIT"
  selected-group["processes"] = processes

  regions := merge-ranges region-inputs
  assign-region-identities regions
  return {
    "regions": regions,
    "capture-scope": {
      "kind": "process-group",
      "planner": "stopped-runtime-layout-v1",
      "selected": selected-group,
      "ownership-catalog": {"program-heaps": program-heaps},
      "included": included,
      "omitted": {"process-group-ids": omitted-group-ids},
      "unresolved": unresolved,
    },
  }

catalog-program-heaps
    reader/target.MemoryReader
    layout/Map
    group-address/int
    group-id/int
    included/List
    region-inputs/List
    program-heaps/List
    -> none:
  process-next-offset := runtime.layout-field-offset
      layout
      "LinkedListElement<toit::Process, 1>"
      "next_"
  anchor := group-address +
      (runtime.layout-field-offset layout "toit::ProcessGroup" "processes_")
  next := read-pointer reader (anchor + process-next-offset)
  seen := {}
  count := 0
  while next and count < MAX-OWNERSHIP-LIST:
    if seen.contains next: throw "PROCESS_OWNERSHIP_LIST_CYCLE"
    seen.add next
    include-range
        included
        region-inputs
        next + process-next-offset
        4
        "process-ownership-list-link"
        "runtime-bootstrap"
        "rw"
    include-layout-field-range
        included
        region-inputs
        layout
        next
        "toit::Process"
        "id_"
        "process-ownership-id"
    include-layout-field-range
        included
        region-inputs
        layout
        next
        "toit::Process"
        "program_heap_address_"
        "process-program-heap-ownership"
    include-layout-field-range
        included
        region-inputs
        layout
        next
        "toit::Process"
        "program_heap_size_"
        "process-program-heap-ownership"
    process-id := read-int32
        reader
        next + (runtime.layout-field-offset layout "toit::Process" "id_")
    address := read-pointer
        reader
        next +
            (runtime.layout-field-offset layout "toit::Process" "program_heap_address_")
    size := read-uint32
        reader
        next + (runtime.layout-field-offset layout "toit::Process" "program_heap_size_")
    if address and size > 0:
      program-heaps.add {
        "process-group-id": group-id,
        "process-id": process-id,
        "address": format.hex-address address,
        "size": size,
      }
    next = read-pointer reader (next + process-next-offset)
    count++
  if count == MAX-OWNERSHIP-LIST: throw "PROCESS_OWNERSHIP_LIST_LIMIT"

plan-process
    reader/target.MemoryReader
    layout/Map
    address/int
    included/List
    region-inputs/List
    unresolved/List
    program-heaps/List
    -> Map:
  process-id := read-int32
      reader
      address + (runtime.layout-field-offset layout "toit::Process" "id_")
  result := {
    "id": process-id,
    "address": format.hex-address address,
  }
  program-address := read-pointer
      reader
      address + (runtime.layout-field-offset layout "toit::Process" "program_heap_address_")
  program-size := read-uint32
      reader
      address + (runtime.layout-field-offset layout "toit::Process" "program_heap_size_")
  result["program-heap"] = {
    "address": pointer-address program-address,
    "size": program-size,
  }
  if program-address and program-size > 0:
    include-range
        included
        region-inputs
        program-address
        program-size
        "selected-program-heap"
        "program-heap"
        "r"

  object-heap := address + (runtime.layout-field-offset layout "toit::Process" "object_heap_")
  program := read-pointer
      reader
      object-heap + (runtime.layout-field-offset layout "toit::ObjectHeap" "program_")
  if not program: throw "PROCESS_PROGRAM_NOT_AVAILABLE"
  external-memory := read-uint32
      reader
      object-heap + (runtime.layout-field-offset layout "toit::ObjectHeap" "external_memory_")
  result["external-memory-bytes"] = external-memory

  globals := read-pointer
      reader
      object-heap + (runtime.layout-field-offset layout "toit::ObjectHeap" "global_variables_")
  if globals:
    globals-table := program +
        (runtime.layout-field-offset layout "toit::Program" "global_variables")
    globals-length := read-int32
        reader
        globals-table +
            (runtime.layout-field-offset
                layout
                "toit::Program::Table<toit::Object*>"
                "length_")
    if globals-length < 0 or globals-length > MAX-OWNERSHIP-LIST:
      throw "INVALID_GLOBAL_VARIABLE_COUNT"
    if globals-length > 0:
      if not reader.allows globals (globals-length * 4):
        throw "GLOBAL_VARIABLES_OUTSIDE_MANIFEST"
      include-range
          included
          region-inputs
          globals
          globals-length * 4
          "process-$(process-id)-global-variables"
          "process-roots"
          "rw"

  native-roots/Map? := null
  native-root-exception := catch:
    native-roots = plan-native-root-metadata
        reader
        layout
        process-id
        object-heap
        included
        region-inputs
        unresolved
  if native-root-exception:
    unresolved.add {
      "kind": "native-root-metadata",
      "process-id": process-id,
      "reason": "LAYOUT_OR_TRAVERSAL_FAILED",
      "context": "$native-root-exception",
    }
  else:
    result["native-roots"] = native-roots

  result["resource-groups"] = plan-resource-groups
      reader
      layout
      process-id
      address
      included
      region-inputs
      unresolved

  two-space := object-heap +
      (runtime.layout-field-offset layout "toit::ObjectHeap" "two_space_heap_")
  external-addresses := {}
  external-stats := {
    "owned-discovered-bytes": 0,
    "owned-captured-bytes": 0,
    "referenced-discovered-bytes": 0,
    "referenced-captured-bytes": 0,
    "references": [],
  }
  plan-space
      reader
      layout
      process-id
      program
      two-space + (runtime.layout-field-offset layout "toit::TwoSpaceHeap" "old_space_")
      "old-space"
      included
      region-inputs
      external-addresses
      unresolved
      program-heaps
      external-stats
  plan-space
      reader
      layout
      process-id
      program
      two-space + (runtime.layout-field-offset layout "toit::TwoSpaceHeap" "semi_space_")
      "new-space"
      included
      region-inputs
      external-addresses
      unresolved
      program-heaps
      external-stats
  owned-discovered/int := external-stats["owned-discovered-bytes"]
  owned-captured/int := external-stats["owned-captured-bytes"]
  referenced-discovered/int := external-stats["referenced-discovered-bytes"]
  referenced-captured/int := external-stats["referenced-captured-bytes"]
  result["discovered-external-payload-bytes"] =
      owned-discovered + referenced-discovered
  result["owned-external-payload-bytes"] = owned-discovered
  result["referenced-program-heap-bytes"] = referenced-discovered
  result["captured-referenced-program-heap-bytes"] = referenced-captured
  result["external-payload-references"] = external-stats["references"]
  captured-owned-external := min owned-captured external-memory
  result["captured-external-memory-bytes"] = captured-owned-external
  if captured-owned-external < external-memory:
    unresolved.add {
      "kind": "external-memory",
      "process-id": process-id,
      "accounted-bytes": external-memory,
      "captured-bytes": captured-owned-external,
      "unresolved-bytes": external-memory - captured-owned-external,
      "reason": "EXTERNAL_ALLOCATION_ADDRESS_NOT_RECOVERED",
    }
  if owned-discovered > external-memory:
    unresolved.add {
      "kind": "external-payload-ownership",
      "process-id": process-id,
      "accounted-bytes": external-memory,
      "discovered-owned-bytes": owned-discovered,
      "unaccounted-bytes": owned-discovered - external-memory,
      "reason": "PAYLOAD_REFERENCED_BUT_NOT_PROCESS_ACCOUNTED",
    }
  return result

plan-native-root-metadata
    reader/target.MemoryReader layout/Map process-id/int object-heap/int
    included/List region-inputs/List unresolved/List
    -> Map:
  notifier-count := plan-double-linked-root-metadata
      reader
      layout
      process-id
      object-heap +
          (runtime.layout-field-offset
              layout
              "toit::ObjectHeap"
              "object_notifiers_")
      "DoubleLinkedListElement<toit::ObjectNotifier, 1>"
      runtime.layout-constant
          layout
          "toit::ObjectNotifier::HEAP_LIST_ELEMENT_OFFSET"
      "toit::ObjectNotifier"
      "object-notifier-root"
      included
      region-inputs
      unresolved
  external-count := plan-double-linked-root-metadata
      reader
      layout
      process-id
      object-heap +
          (runtime.layout-field-offset layout "toit::ObjectHeap" "external_roots_")
      "DoubleLinkedListElement<toit::HeapRoot, 1>"
      runtime.layout-constant layout "toit::HeapRoot::HEAP_LIST_ELEMENT_OFFSET"
      "toit::HeapRoot"
      "external-root"
      included
      region-inputs
      unresolved
  finalizer-count := 0
  [
    ["runnable-finalizer", "runnable_finalizers_"],
    ["registered-callback-finalizer", "registered_callback_finalizers_"],
    ["registered-vm-finalizer", "registered_vm_finalizers_"],
  ].do: | names/List |
    finalizer-count += plan-finalizer-metadata
        reader
        layout
        process-id
        object-heap +
            (runtime.layout-field-offset layout "toit::ObjectHeap" names[1])
        names[0]
        included
        region-inputs
        unresolved
  return {
    "object-notifier-count": notifier-count,
    "external-root-count": external-count,
    "finalizer-count": finalizer-count,
  }

plan-double-linked-root-metadata
    reader/target.MemoryReader layout/Map process-id/int anchor/int
    element-type/string element-offset/int container-type/string kind/string
    included/List region-inputs/List unresolved/List
    -> int:
  next-offset := runtime.layout-field-offset layout element-type "next_"
  size := layout-type-size layout container-type
  next := read-pointer reader (anchor + next-offset)
  seen := {}
  count := 0
  while next and next != anchor and count < MAX-OWNERSHIP-LIST:
    if seen.contains next: throw "NATIVE_ROOT_LIST_CYCLE"
    seen.add next
    address := next - element-offset
    if not reader.allows address size:
      unresolved.add {
        "kind": kind,
        "process-id": process-id,
        "address": format.hex-address address,
        "reason": "OUTSIDE_SOURCE_MEMORY_MAP",
      }
      break
    include-typed-range
        included
        region-inputs
        layout
        address
        container-type
        "process-$(process-id)-$kind"
        "process-root-metadata"
    next = read-pointer reader (next + next-offset)
    count++
  if count == MAX-OWNERSHIP-LIST: throw "NATIVE_ROOT_LIST_LIMIT"
  return count

plan-finalizer-metadata
    reader/target.MemoryReader layout/Map process-id/int list-address/int kind/string
    included/List region-inputs/List unresolved/List
    -> int:
  element-offset := runtime.layout-constant
      layout
      "toit::FinalizerNode::HEAP_LIST_ELEMENT_OFFSET"
  next-offset := runtime.layout-field-offset
      layout
      "LinkedListElement<toit::FinalizerNode, 1>"
      "next_"
  base-size := layout-type-size layout "toit::FinalizerNode"
  next := read-pointer reader list-address
  seen := {}
  count := 0
  while next and count < MAX-OWNERSHIP-LIST:
    if seen.contains next: throw "FINALIZER_LIST_CYCLE"
    seen.add next
    address := next - element-offset
    if not reader.allows address base-size:
      unresolved.add {
        "kind": kind,
        "process-id": process-id,
        "address": format.hex-address address,
        "reason": "OUTSIDE_SOURCE_MEMORY_MAP",
      }
      break
    vtable := read-uint32 reader address
    dynamic-type := dynamic-type-for-vtable layout vtable
    dynamic-size := layout-type-size-if-present layout dynamic-type
    capture-size := dynamic-size or base-size
    if not reader.allows address capture-size:
      capture-size = base-size
      unresolved.add {
        "kind": kind,
        "process-id": process-id,
        "address": format.hex-address address,
        "dynamic-type": dynamic-type,
        "reason": "DYNAMIC_NODE_OUTSIDE_SOURCE_MEMORY_MAP",
      }
    include-range
        included
        region-inputs
        address
        capture-size
        "process-$(process-id)-$kind"
        "process-root-metadata"
        "rw"
    if not dynamic-type:
      unresolved.add {
        "kind": kind,
        "process-id": process-id,
        "address": format.hex-address address,
        "reason": "UNKNOWN_DYNAMIC_TYPE",
      }
    next = read-pointer reader (next + next-offset)
    count++
  if count == MAX-OWNERSHIP-LIST: throw "FINALIZER_LIST_LIMIT"
  return count

plan-resource-groups
    reader/target.MemoryReader
    layout/Map
    process-id/int
    process-address/int
    included/List
    region-inputs/List
    unresolved/List
    -> List:
  result := []
  group-size := layout-type-size layout "toit::ResourceGroup"
  group-next-offset := layout-constant
      layout
      "toit::ResourceGroup::PROCESS_LIST_NEXT_OFFSET"
  anchor := process-address +
      (runtime.layout-field-offset layout "toit::Process" "resource_groups_")
  next-element := read-pointer reader anchor
  seen := {}
  count := 0
  while next-element and count < MAX-OWNERSHIP-LIST:
    if seen.contains next-element: throw "RESOURCE_GROUP_LIST_CYCLE"
    seen.add next-element
    address := next-element - group-next-offset
    if not reader.allows address group-size:
      unresolved.add {
        "kind": "native-resource-group-list",
        "process-id": process-id,
        "address": format.hex-address address,
        "reason": "OUTSIDE_SOURCE_MEMORY_MAP",
      }
      next-element = null
      continue
    include-typed-range
        included
        region-inputs
        layout
        address
        "toit::ResourceGroup"
        "process-$(process-id)-resource-group-metadata"
        "native-resource-metadata"
    vtable := read-uint32 reader address
    dynamic-type := dynamic-type-for-vtable layout vtable
    dynamic-size := layout-type-size-if-present layout dynamic-type
    captured-size := group-size
    if dynamic-size:
      if dynamic-size < group-size: throw "INVALID_RESOURCE_GROUP_DYNAMIC_SIZE"
      if dynamic-size > group-size:
        if reader.allows address dynamic-size:
          include-range
              included
              region-inputs
              address
              dynamic-size
              "process-$(process-id)-$(dynamic-type)-metadata"
              "native-resource-metadata"
              "rw"
          captured-size = dynamic-size
        else:
          unresolved.add {
            "kind": "native-resource-group-extension",
            "process-id": process-id,
            "address": format.hex-address address,
            "dynamic-type": dynamic-type,
            "captured-base-bytes": group-size,
            "reason": "OUTSIDE_SOURCE_MEMORY_MAP",
          }
    owner := read-pointer
        reader
        address + (runtime.layout-field-offset layout "toit::ResourceGroup" "process_")
    event-source := read-pointer
        reader
        address + (runtime.layout-field-offset layout "toit::ResourceGroup" "event_source_")
    group := {
      "address": format.hex-address address,
      "vtable": format.hex-address vtable,
      "dynamic-type": dynamic-type,
      "captured-bytes": captured-size,
      "event-source": pointer-address event-source,
    }
    if owner != process-address:
      unresolved.add {
        "kind": "native-resource-group-owner",
        "process-id": process-id,
        "address": format.hex-address address,
        "recorded-owner": pointer-address owner,
        "reason": "OWNER_MISMATCH",
      }
    resources := plan-resources
        reader
        layout
        process-id
        address
        included
        region-inputs
        unresolved
    group["resources"] = resources
    result.add group
    if not dynamic-size:
      unresolved.add {
        "kind": "native-resource-group-extension",
        "process-id": process-id,
        "address": format.hex-address address,
        "dynamic-type": dynamic-type,
        "captured-base-bytes": group-size,
        "reason": "TYPE_SPECIFIC_LAYOUT_NOT_DECLARED",
      }
    else if layout-type-is-size-only layout dynamic-type:
      unresolved.add {
        "kind": "native-resource-group-dependencies",
        "process-id": process-id,
        "address": format.hex-address address,
        "dynamic-type": dynamic-type,
        "captured-bytes": captured-size,
        "reason": "TYPE_SPECIFIC_POINTERS_NOT_DECLARED",
      }
    next-element = read-pointer reader next-element
    count++
  if count == MAX-OWNERSHIP-LIST: throw "RESOURCE_GROUP_LIST_LIMIT"
  return result

plan-resources
    reader/target.MemoryReader
    layout/Map
    process-id/int
    group-address/int
    included/List
    region-inputs/List
    unresolved/List
    -> List:
  result := []
  resource-size := layout-type-size layout "toit::Resource"
  resource-next-offset := layout-constant
      layout
      "toit::Resource::GROUP_LIST_NEXT_OFFSET"
  anchor := group-address +
      (runtime.layout-field-offset layout "toit::ResourceGroup" "resources_")
  anchor-next-offset := runtime.layout-field-offset
      layout
      "DoubleLinkedListElement<toit::Resource, 1>"
      "next_"
  next-element := read-pointer reader (anchor + anchor-next-offset)
  seen := {}
  count := 0
  while next-element and next-element != anchor and count < MAX-OWNERSHIP-LIST:
    if seen.contains next-element: throw "RESOURCE_LIST_CYCLE"
    seen.add next-element
    address := next-element - resource-next-offset
    if not reader.allows address resource-size:
      unresolved.add {
        "kind": "native-resource-list",
        "process-id": process-id,
        "resource-group": format.hex-address group-address,
        "address": format.hex-address address,
        "reason": "OUTSIDE_SOURCE_MEMORY_MAP",
      }
      next-element = null
      continue
    include-typed-range
        included
        region-inputs
        layout
        address
        "toit::Resource"
        "process-$(process-id)-native-resource-metadata"
        "native-resource-metadata"
    vtable := read-uint32 reader address
    dynamic-type := dynamic-type-for-vtable layout vtable
    dynamic-size := layout-type-size-if-present layout dynamic-type
    captured-size := resource-size
    if dynamic-size:
      if dynamic-size < resource-size: throw "INVALID_RESOURCE_DYNAMIC_SIZE"
      if dynamic-size > resource-size:
        if reader.allows address dynamic-size:
          include-range
              included
              region-inputs
              address
              dynamic-size
              "process-$(process-id)-$(dynamic-type)-metadata"
              "native-resource-metadata"
              "rw"
          captured-size = dynamic-size
        else:
          unresolved.add {
            "kind": "native-resource-extension",
            "process-id": process-id,
            "address": format.hex-address address,
            "dynamic-type": dynamic-type,
            "captured-base-bytes": resource-size,
            "reason": "OUTSIDE_SOURCE_MEMORY_MAP",
          }
    owner := read-pointer
        reader
        address + (runtime.layout-field-offset layout "toit::Resource" "resource_group_")
    state := read-uint32
        reader
        address + (runtime.layout-field-offset layout "toit::Resource" "state_")
    notifier := read-pointer
        reader
        address + (runtime.layout-field-offset layout "toit::Resource" "object_notifier_")
    resource := {
      "address": format.hex-address address,
      "vtable": format.hex-address vtable,
      "dynamic-type": dynamic-type,
      "captured-bytes": captured-size,
      "state": state,
      "object-notifier": pointer-address notifier,
    }
    if dynamic-type == "toit::Timer" and captured-size == dynamic-size:
      resource["fields"] = {
        "timeout-us": read-int64
            reader
            address + (runtime.layout-field-offset layout "toit::Timer" "timeout_"),
      }
    if dynamic-type == "toit::IntResource" and captured-size == dynamic-size:
      resource["fields"] = {
        "id": read-int32
            reader
            address + (runtime.layout-field-offset layout "toit::IntResource" "id_"),
      }
    if owner != group-address:
      unresolved.add {
        "kind": "native-resource-owner",
        "process-id": process-id,
        "address": format.hex-address address,
        "recorded-owner": pointer-address owner,
        "reason": "OWNER_MISMATCH",
      }
    if notifier:
      resource["notifier-evidence"] = plan-object-notifier
          reader
          layout
          process-id
          notifier
          included
          region-inputs
          unresolved
    result.add resource
    if not dynamic-size:
      unresolved.add {
        "kind": "native-resource-extension",
        "process-id": process-id,
        "address": format.hex-address address,
        "dynamic-type": dynamic-type,
        "captured-base-bytes": resource-size,
        "reason": "TYPE_SPECIFIC_LAYOUT_NOT_DECLARED",
      }
    else if layout-type-is-size-only layout dynamic-type:
      unresolved.add {
        "kind": "native-resource-dependencies",
        "process-id": process-id,
        "address": format.hex-address address,
        "dynamic-type": dynamic-type,
        "captured-bytes": captured-size,
        "reason": "TYPE_SPECIFIC_POINTERS_NOT_DECLARED",
      }
    next-element = read-pointer reader next-element
    count++
  if count == MAX-OWNERSHIP-LIST: throw "RESOURCE_LIST_LIMIT"
  return result

plan-object-notifier
    reader/target.MemoryReader
    layout/Map
    process-id/int
    address/int
    included/List
    region-inputs/List
    unresolved/List
    -> Map:
  size := layout-type-size layout "toit::ObjectNotifier"
  if not reader.allows address size:
    unresolved.add {
      "kind": "object-notifier",
      "process-id": process-id,
      "address": format.hex-address address,
      "reason": "OUTSIDE_SOURCE_MEMORY_MAP",
    }
    return {"address": format.hex-address address, "captured": false}
  include-typed-range
      included
      region-inputs
      layout
      address
      "toit::ObjectNotifier"
      "process-$(process-id)-object-notifier"
      "native-resource-metadata"
  owner := read-pointer
      reader
      address + (runtime.layout-field-offset layout "toit::ObjectNotifier" "process_")
  object := read-uint32
      reader
      address + (runtime.layout-field-offset layout "toit::ObjectNotifier" "object_")
  message := read-pointer
      reader
      address + (runtime.layout-field-offset layout "toit::ObjectNotifier" "message_")
  result := {
    "address": format.hex-address address,
    "captured": true,
    "process": pointer-address owner,
    "object-reference": format.hex-address object,
    "message": pointer-address message,
  }
  if message:
    message-size := layout-type-size layout "toit::ObjectNotifyMessage"
    if reader.allows message message-size:
      include-typed-range
          included
          region-inputs
          layout
          message
          "toit::ObjectNotifyMessage"
          "process-$(process-id)-object-notify-message"
          "native-resource-metadata"
      result["message-evidence"] = {
        "captured": true,
        "notifier": pointer-address
            (read-pointer
                reader
                message +
                    (runtime.layout-field-offset
                        layout
                        "toit::ObjectNotifyMessage"
                        "notifier_")),
        "queued": (reader.read
            (message +
                (runtime.layout-field-offset
                    layout
                    "toit::ObjectNotifyMessage"
                    "queued_"))
            1)[0] != 0,
      }
    else:
      unresolved.add {
        "kind": "object-notifier-message",
        "process-id": process-id,
        "notifier-address": format.hex-address address,
        "address": format.hex-address message,
        "reason": "OUTSIDE_SOURCE_MEMORY_MAP",
      }
      result["message-evidence"] = {"captured": false}
  return result

dynamic-type-for-vtable layout/Map address/int -> string?:
  vtables/List? := layout.get "vtables"
  if not vtables: return null
  vtables.do: | entry/Map |
    address-point := entry.get "address-point"
    if not address-point is string: continue.do
    if (format.parse-address address-point) == address:
      return entry.get "name"
  return null

layout-type-size-if-present layout/Map name/string? -> int?:
  if not name: return null
  types/Map := layout["types"]
  type/Map? := types.get name
  if not type: return null
  size := type.get "size"
  if not size is int or size <= 0: return null
  return size

layout-type-is-size-only layout/Map name/string? -> bool:
  if not name: return false
  types/Map := layout["types"]
  type/Map? := types.get name
  return type and type.get "dynamic-size-only" --if-absent=: false

plan-space
    reader/target.MemoryReader
    layout/Map
    process-id/int
    program/int
    space/int
    name/string
    included/List
    region-inputs/List
    external-addresses/Set
    unresolved/List
    program-heaps/List
    external-stats/Map
    -> none:
  list-offset := runtime.layout-field-offset layout "toit::Space" "chunk_list_"
  next-offset := runtime.layout-field-offset
      layout
      "DoubleLinkedListElement<toit::Chunk, 1>"
      "next_"
  anchor := space + list-offset
  next := read-pointer reader (anchor + next-offset)
  seen := {}
  count := 0
  while next and next != anchor and count < MAX-OWNERSHIP-LIST:
    if seen.contains next: throw "CHUNK_LIST_CYCLE"
    seen.add next
    include-typed-range
        included
        region-inputs
        layout
        next
        "toit::Chunk"
        "$(name)-chunk-metadata"
        "runtime-bootstrap"
    start := read-pointer
        reader
        next + (runtime.layout-field-offset layout "toit::Chunk" "start_")
    end := read-pointer
        reader
        next + (runtime.layout-field-offset layout "toit::Chunk" "end_")
    if not start or not end or end <= start: throw "INVALID_CHUNK_RANGE"
    if not reader.allows start (end - start): throw "CHUNK_OUTSIDE_MANIFEST"
    include-range
        included
        region-inputs
        start
        end - start
        "$(name)-process-$process-id"
        "process-heap"
        "rw"
    discover-external-payloads
        reader
        layout
        program
        start
        end
        included
        region-inputs
        external-addresses
        unresolved
        program-heaps
        external-stats
    next = read-pointer reader (next + next-offset)
    count++
  if count == MAX-OWNERSHIP-LIST: throw "CHUNK_LIST_LIMIT"

discover-external-payloads
    reader/target.MemoryReader
    layout/Map
    program/int
    start/int
    end/int
    included/List
    region-inputs/List
    external-addresses/Set
    unresolved/List
    program-heaps/List
    external-stats/Map
    -> none:
  current := start
  object-count := 0
  while current + 4 <= end and object-count < MAX-HEAP-OBJECTS:
    header := read-uint32 reader current
    if header == 0: return
    evidence := object-evidence reader layout program current header
    size/int := evidence["size"]
    if size <= 0 or (size & 3) != 0 or current + size > end:
      throw "INVALID_HEAP_OBJECT_SIZE"
    external/Map? := evidence.get "external"
    if external:
      external-address/int := external["address"]
      external-size/int := external["size"]
      if external-size > 0 and not external-addresses.contains external-address:
        external-addresses.add external-address
        program-owner := find-program-heap-owner
            program-heaps
            external-address
            external-size
        if program-owner:
          external-stats["referenced-discovered-bytes"] += external-size
        else:
          external-stats["owned-discovered-bytes"] += external-size
        if reader.allows external-address external-size:
          include-range
              included
              region-inputs
              external-address
              external-size
              (program-owner
                  ? "referenced-$(external["kind"])-object-$(format.hex-address current)"
                  : "$(external["kind"])-object-$(format.hex-address current)")
              "external-payload"
              "rw"
          if program-owner:
            external-stats["referenced-captured-bytes"] += external-size
          else:
            external-stats["owned-captured-bytes"] += external-size
        else:
          unresolved.add {
            "kind": external["kind"],
            "object-address": format.hex-address current,
            "address": format.hex-address external-address,
            "bytes": external-size,
            "reason": "OUTSIDE_SOURCE_MEMORY_MAP",
          }
        references/List := external-stats["references"]
        reference := {
          "object-address": format.hex-address current,
          "payload-kind": external["kind"],
          "address": format.hex-address external-address,
          "bytes": external-size,
          "captured": reader.allows external-address external-size,
          "process-accounted": not program-owner,
        }
        if program-owner: reference["owner"] = program-owner
        references.add reference
    current += size
    object-count++
  if object-count == MAX-HEAP-OBJECTS: throw "HEAP_OBJECT_LIST_LIMIT"
  throw "HEAP_SENTINEL_NOT_FOUND"

find-program-heap-owner program-heaps/List address/int size/int -> Map?:
  end := address + size
  program-heaps.do: | heap/Map |
    start := format.parse-address heap["address"]
    if address >= start and end <= start + heap["size"]:
      return {
        "kind": "program-heap",
        "process-group-id": heap["process-group-id"],
        "process-id": heap["process-id"],
        "address": heap["address"],
        "size": heap["size"],
      }
  return null

object-evidence
    reader/target.MemoryReader layout/Map program/int address/int header/int
    -> Map:
  header-value := read-signed-value header >> 1
  type-tag := header-value & 0xf
  class-id := header-value >> 5
  if type-tag == 0:
    return {"size": aligned-size 8 + (read-uint32 reader (address + 4)) * 4}
  if type-tag == 1:
    internal-length-offset := layout-constant layout "toit::String::INTERNAL_LENGTH_OFFSET"
    internal-length := read-uint16 reader (address + internal-length-offset)
    if internal-length != 0xffff:
      return {"size": aligned-size 8 + internal-length + 1}
    length := read-uint32
        reader
        address + (layout-constant layout "toit::String::EXTERNAL_LENGTH_OFFSET")
    external-address := read-uint32
        reader
        address + (layout-constant layout "toit::String::EXTERNAL_ADDRESS_OFFSET")
    return {
      "size": 16,
      "external": {
        "kind": "external-string",
        "address": external-address,
        "size": length + 1,
      },
    }
  if type-tag == 4 or type-tag == 6: return {"size": 12}
  if type-tag == 5:
    raw-length := read-int32
        reader
        address + (layout-constant layout "toit::ByteArray::LENGTH_OFFSET")
    if raw-length >= 0: return {"size": aligned-size 8 + raw-length}
    length := -1 - raw-length
    external-address := read-uint32
        reader
        address + (layout-constant layout "toit::ByteArray::EXTERNAL_ADDRESS_OFFSET")
    external-tag := read-uint32
        reader
        address + (layout-constant layout "toit::ByteArray::EXTERNAL_TAG_OFFSET")
    result := {"size": 16}
    if external-tag == 0 and external-address:
      result["external"] = {
        "kind": "external-byte-array",
        "address": external-address,
        "size": length,
      }
    return result
  if type-tag == 7:
    length := read-uint32
        reader
        address + (layout-constant layout "toit::Stack::LENGTH_OFFSET")
    return {
      "size": aligned-size
          (layout-constant layout "toit::Stack::HEADER_SIZE") + length * 4,
    }
  if type-tag == 9:
    return {"size": read-uint32 reader (address + 4)}
  if type-tag == 10: return {"size": 4}
  if type-tag == 11:
    return {"size": (read-uint32 reader (address + 4)) - address}
  if type-tag == 2 or type-tag == 3 or type-tag == 8:
    return {"size": instance-size reader layout program class-id}
  throw "UNKNOWN_HEAP_OBJECT_TYPE"

instance-size reader/target.MemoryReader layout/Map program/int class-id/int -> int:
  if class-id < 0: throw "INVALID_HEAP_CLASS_ID"
  table := program + (runtime.layout-field-offset layout "toit::Program" "class_bits")
  data := read-pointer
      reader
      table + (runtime.layout-field-offset layout "toit::List<unsigned short>" "data_")
  length := read-int32
      reader
      table + (runtime.layout-field-offset layout "toit::List<unsigned short>" "length_")
  if not data or class-id >= length: throw "INVALID_HEAP_CLASS_ID"
  class-bits := read-uint16 reader (data + class-id * 2)
  size := ((class-bits >> 5) & 0x7ff) * 4
  if size <= 0: throw "INVALID_FIXED_HEAP_OBJECT_SIZE"
  return size

include-typed-range
    included/List
    region-inputs/List
    layout/Map
    address/int
    type-name/string
    reason/string
    kind/string
    -> none:
  size := layout-type-size layout type-name
  include-range included region-inputs address size reason kind "rw"

include-layout-field-range
    included/List
    region-inputs/List
    layout/Map
    address/int
    type-name/string
    field-name/string
    reason/string
    -> none:
  types/Map := layout["types"]
  type/Map := types[type-name]
  fields/List := type["fields"]
  field/Map? := null
  fields.do: | candidate/Map |
    candidate-name := candidate.get "name"
    if candidate-name == field-name: field = candidate
  if not field: throw "RUNTIME_LAYOUT_FIELD_MISSING"
  offset := field.get "offset"
  size := field.get "size"
  if not offset is int or not size is int or size <= 0:
    throw "RUNTIME_LAYOUT_FIELD_MISSING"
  include-range
      included
      region-inputs
      address + offset
      size
      reason
      "runtime-bootstrap"
      "rw"

include-range
    included/List
    region-inputs/List
    address/int
    size/int
    reason/string
    kind/string
    permissions/string
    -> none:
  if address <= 0 or size <= 0: throw "INVALID_PLANNED_RANGE"
  included.add {
    "address": format.hex-address address,
    "size": size,
    "reason": reason,
  }
  region-inputs.add {
    "address": address,
    "size": size,
    "kind": kind,
    "permissions": permissions,
  }

merge-ranges inputs/List -> List:
  inputs.sort --in-place: | a/Map b/Map | a["address"] - b["address"]
  result := []
  inputs.do: | input/Map |
    if result.is-empty:
      result.add input.copy
      continue.do
    previous/Map := result.last
    previous-end := previous["address"] + previous["size"]
    input-end := input["address"] + input["size"]
    same-classification := input["kind"] == previous["kind"] and
        input["permissions"] == previous["permissions"]
    overlaps := input["address"] < previous-end
    if overlaps or (input["address"] == previous-end and same-classification):
      if input-end > previous-end:
        previous["size"] = input-end - previous["address"]
      if overlaps and not same-classification:
        previous["kind"] = "mixed"
        previous["permissions"] = merge-permissions
            previous["permissions"]
            input["permissions"]
    else:
      result.add input.copy
  return result

merge-permissions first/string second/string -> string:
  result := ""
  "rwx".do: | permission/int |
    character := string.from-rune permission
    if first.contains character or second.contains character: result += character
  return result

assign-region-identities regions/List -> none:
  index := 0
  regions.do: | region/Map |
    suffix := index.to-string
    while suffix.size < 3: suffix = "0$suffix"
    region["id"] = "scope-$suffix"
    region["name"] = "Selective capture region $suffix"
    region["file"] = "scope-$(suffix).bin"
    region["address"] = format.hex-address region["address"]
    index++

layout-type-size layout/Map name/string -> int:
  types/Map := layout["types"]
  type/Map := types[name]
  size := type.get "size"
  if not size is int or size <= 0: throw "RUNTIME_LAYOUT_TYPE_MISSING"
  return size

layout-constant layout/Map name/string -> int:
  constants/Map := layout["constants"]
  value := constants.get name
  if not value is int or value < 0: throw "RUNTIME_LAYOUT_CONSTANT_MISSING"
  return value

read-pointer reader/target.MemoryReader address/int -> int?:
  value := read-uint32 reader address
  return value == 0 ? null : value

read-uint32 reader/target.MemoryReader address/int -> int:
  return LITTLE-ENDIAN.uint32 (reader.read address 4) 0

read-int64 reader/target.MemoryReader address/int -> int:
  return LITTLE-ENDIAN.int64 (reader.read address 8) 0

read-uint16 reader/target.MemoryReader address/int -> int:
  return LITTLE-ENDIAN.uint16 (reader.read address 2) 0

read-int32 reader/target.MemoryReader address/int -> int:
  value := read-uint32 reader address
  return read-signed-value value

read-signed-value value/int -> int:
  return value >= 0x8000_0000 ? value - 0x1_0000_0000 : value

aligned-size value/int -> int:
  return (value + 3) & ~3

pointer-address value/int? -> string?:
  return value ? format.hex-address value : null
