// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import io show LITTLE-ENDIAN

import ..capture-scope
import ..target as target

class SparseMemory implements target.MemoryReader:
  bytes_/Map := {:}

  put-uint32 address/int value/int -> none:
    encoded := ByteArray 4
    LITTLE-ENDIAN.put-uint32 encoded 0 value
    4.repeat: bytes_[address + it] = encoded[it]

  read address/int length/int -> ByteArray:
    result := ByteArray length
    length.repeat:
      value := bytes_.get address + it
      if not value is int: throw "TEST_ADDRESS_NOT_AVAILABLE"
      result[it] = value
    return result

  allows address/int length/int -> bool:
    return address > 0 and length > 0

main:
  memory := SparseMemory
  memory.put-uint32 0x1000 0x2000
  memory.put-uint32 0x2000 0x3000

  // Scheduler group anchor -> group 0 -> selected group 2 -> anchor.
  memory.put-uint32 0x3000 0x4000
  memory.put-uint32 0x4000 0x5000
  memory.put-uint32 0x4004 0
  memory.put-uint32 0x4010 0x6100
  memory.put-uint32 0x6100 0
  memory.put-uint32 0x6104 3
  memory.put-uint32 0x6108 0xc100
  memory.put-uint32 0x610c 0x100
  memory.put-uint32 0x5000 0x3000
  memory.put-uint32 0x5004 2
  memory.put-uint32 0x5008 0x9000
  memory.put-uint32 0x500c 0xe000
  memory.put-uint32 0x5010 0x6000

  // One process with one old-space and one new-space chunk.
  memory.put-uint32 0x6000 0
  memory.put-uint32 0x6004 7
  memory.put-uint32 0x6008 0x9000
  memory.put-uint32 0x600c 0x100
  memory.put-uint32 0x60e8 0xd004
  memory.put-uint32 0x6084 64
  memory.put-uint32 0x6088 0xc000
  memory.put-uint32 0x608c 0x608c
  memory.put-uint32 0x6094 0x6094
  memory.put-uint32 0x609c 0
  memory.put-uint32 0x60a4 0
  memory.put-uint32 0x60ac 0xf104
  memory.put-uint32 0x6020 0x9000
  memory.put-uint32 0x9024 2
  memory.put-uint32 0x6030 0x7000
  memory.put-uint32 0x6070 0x7100
  memory.put-uint32 0x7000 0x6030
  memory.put-uint32 0x7004 0xa000
  memory.put-uint32 0x7008 0xa100
  memory.put-uint32 0x7100 0x6070
  memory.put-uint32 0x7104 0xb000
  memory.put-uint32 0x7108 0xb080
  // An external byte-array payload points into the omitted process's program
  // heap. It is referenced by the selected process, but is not owned external
  // memory of that process.
  memory.put-uint32 0xa000 10
  memory.put-uint32 0xa004 0xffff_fff0
  memory.put-uint32 0xa008 0xc120
  memory.put-uint32 0xa00c 0
  memory.put-uint32 0xa010 0
  memory.put-uint32 0xb000 0

  // One simple native resource group with one resource and notifier.
  memory.put-uint32 0xd000 0x1110
  memory.put-uint32 0xd004 0
  memory.put-uint32 0xd008 0x6000
  memory.put-uint32 0xd00c 0xd100
  memory.put-uint32 0xd010 0xe004
  memory.put-uint32 0xe000 0x2220
  memory.put-uint32 0xe004 0xe104
  memory.put-uint32 0xe014 0xd000
  memory.put-uint32 0xe018 55
  memory.put-uint32 0xe01c 0xf000
  memory.put-uint32 0xe020 99
  memory.put-uint32 0xe100 0x3330
  memory.put-uint32 0xe104 0xd010
  memory.put-uint32 0xe114 0xd000
  memory.put-uint32 0xe118 77
  memory.put-uint32 0xe11c 0
  memory.put-uint32 0xf000 0
  memory.put-uint32 0xf004 0
  memory.put-uint32 0xf008 0x6000
  memory.put-uint32 0xf00c 0xa001
  memory.put-uint32 0xf010 0
  // One VM finalizer node in the selected process's registered queue.
  memory.put-uint32 0xf100 0x4440
  memory.put-uint32 0xf104 0
  memory.put-uint32 0xf108 0xa001
  memory.put-uint32 0xf10c 0x6020

  plan := plan-process-group memory LAYOUT 2
  scope/Map := plan["capture-scope"]
  expect-equals "process-group" scope["kind"]
  expect-equals 2 scope["selected"]["id"]
  expect-equals [0] scope["omitted"]["process-group-ids"]
  expect-equals 7 scope["selected"]["processes"][0]["id"]
  expect-equals 64 scope["selected"]["processes"][0]["external-memory-bytes"]
  expect-equals 15 scope["selected"]["processes"][0]["referenced-program-heap-bytes"]
  expect-equals 0 scope["selected"]["processes"][0]["owned-external-payload-bytes"]
  references/List := scope["selected"]["processes"][0]["external-payload-references"]
  expect-equals 1 references.size
  expect-not references[0]["process-accounted"]
  expect-equals 0 references[0]["owner"]["process-group-id"]
  expect-equals 3 references[0]["owner"]["process-id"]
  catalog/List := scope["ownership-catalog"]["program-heaps"]
  expect-equals 2 catalog.size
  expect (catalog.any:
    it["process-group-id"] == 0 and
        it["process-id"] == 3 and
        it["address"] == "0xc100" and
        it["size"] == 0x100)
  resource-groups/List := scope["selected"]["processes"][0]["resource-groups"]
  expect-equals 1 resource-groups.size
  expect-equals "toit::SimpleResourceGroup" resource-groups[0]["dynamic-type"]
  expect-equals 2 resource-groups[0]["resources"].size
  expect-equals "toit::IntResource" resource-groups[0]["resources"][0]["dynamic-type"]
  expect-equals 55 resource-groups[0]["resources"][0]["state"]
  expect-equals 99 resource-groups[0]["resources"][0]["fields"]["id"]
  expect-equals "toit::OpaqueResource" resource-groups[0]["resources"][1]["dynamic-type"]
  expect-equals 44 resource-groups[0]["resources"][1]["captured-bytes"]
  expect-equals 1 scope["selected"]["processes"][0]["native-roots"]["finalizer-count"]
  expect-equals 3 scope["unresolved"].size
  expect (scope["unresolved"].any:
    it["kind"] == "native-resource-dependencies" and
        it["dynamic-type"] == "toit::OpaqueResource")

  regions/List := plan["regions"]
  expect (regions.any: it["address"] == "0x9000" and it["size"] == 0x100)
  expect (regions.any: it["address"] == "0xa000" and it["size"] == 0x100)
  expect (regions.any: it["address"] == "0xb000" and it["size"] == 0x80)
  expect (regions.any: it["address"] == "0xc000" and it["size"] == 8)
  expect (regions.any: it["address"] == "0xf100" and it["size"] == 16)
  expect (regions.every: it["id"].starts-with "scope-")

  merged := merge-ranges [
    {"address": 0x1000, "size": 0x100, "kind": "program-heap", "permissions": "r"},
    {"address": 0x1008, "size": 16, "kind": "external-payload", "permissions": "rw"},
  ]
  expect-equals 1 merged.size
  expect-equals "mixed" merged[0]["kind"]
  expect-equals "rw" merged[0]["permissions"]

field name/string offset/int -> Map:
  return {"name": name, "offset": offset, "size": 4}

type size/int fields/List -> Map:
  return {"size": size, "fields": fields}

LAYOUT ::= {
  "format": "toit-runtime-layout",
  "format-version": 1,
  "pointer-size": 4,
  "byte-order": "little",
  "symbols": {
    "toit::VM::current_": {"present": true, "address": "0x1000"},
  },
  "types": {
    "toit::VM": type 16 [field "scheduler_" 0],
    "toit::Scheduler": type 64 [field "groups_" 0],
    "toit::ProcessGroup": type 32 [
      field "id_" 4,
      field "program_" 8,
      field "memory_" 12,
      field "processes_" 16,
    ],
    "toit::Process": type 256 [
      field "id_" 4,
      field "program_heap_address_" 8,
      field "program_heap_size_" 12,
      field "object_heap_" 32,
      field "resource_groups_" 232,
    ],
    "toit::ResourceGroup": type 24 [
      field "process_" 8,
      field "event_source_" 12,
      field "resources_" 16,
    ],
    "toit::Resource": type 32 [
      field "resource_group_" 20,
      field "state_" 24,
      field "object_notifier_" 28,
    ],
    "toit::ObjectNotifier": type 20 [
      field "process_" 8,
      field "object_" 12,
      field "message_" 16,
    ],
    "toit::HeapRoot": type 12 [field "obj_" 8],
    "toit::FinalizerNode": type 16 [field "key_" 8],
    "toit::VmFinalizerNode": type 16 [],
    "toit::SimpleResourceGroup": type 24 [],
    "toit::IntResource": type 36 [field "id_" 32],
    "toit::OpaqueResource": {
      "size": 44,
      "fields": [],
      "dynamic-size-only": true,
    },
    "toit::ObjectHeap": type 160 [
      field "program_" 0,
      field "two_space_heap_" 16,
      field "external_memory_" 100,
      field "global_variables_" 104,
      field "object_notifiers_" 108,
      field "external_roots_" 116,
      field "runnable_finalizers_" 124,
      field "registered_callback_finalizers_" 132,
      field "registered_vm_finalizers_" 140,
    ],
    "toit::TwoSpaceHeap": type 128 [
      field "old_space_" 0,
      field "semi_space_" 64,
    ],
    "toit::Space": type 32 [field "chunk_list_" 0],
    "toit::Chunk": type 32 [
      field "start_" 4,
      field "end_" 8,
    ],
    "toit::Program": type 64 [field "global_variables" 32],
    "toit::Program::Table<toit::Object*>": type 8 [field "length_" 4],
    "DoubleLinkedListElement<toit::ProcessGroup, 1>": type 8 [field "next_" 0],
    "LinkedListElement<toit::Process, 1>": type 4 [field "next_" 0],
    "DoubleLinkedListElement<toit::Chunk, 1>": type 8 [field "next_" 0],
    "DoubleLinkedListElement<toit::Resource, 1>": type 8 [field "next_" 0],
    "DoubleLinkedListElement<toit::ObjectNotifier, 1>": type 8 [field "next_" 0],
    "DoubleLinkedListElement<toit::HeapRoot, 1>": type 8 [field "next_" 0],
    "LinkedListElement<toit::FinalizerNode, 1>": type 4 [field "next_" 0],
  },
  "constants": {
    "toit::ResourceGroup::PROCESS_LIST_NEXT_OFFSET": 4,
    "toit::Resource::GROUP_LIST_NEXT_OFFSET": 4,
    "toit::ObjectNotifier::HEAP_LIST_ELEMENT_OFFSET": 0,
    "toit::HeapRoot::HEAP_LIST_ELEMENT_OFFSET": 0,
    "toit::FinalizerNode::HEAP_LIST_ELEMENT_OFFSET": 4,
    "toit::ByteArray::LENGTH_OFFSET": 4,
    "toit::ByteArray::EXTERNAL_ADDRESS_OFFSET": 8,
    "toit::ByteArray::EXTERNAL_TAG_OFFSET": 12,
  },
  "vtables": [
    {
      "name": "toit::SimpleResourceGroup",
      "symbol-address": "0x1108",
      "address-point": "0x1110",
    },
    {
      "name": "toit::IntResource",
      "symbol-address": "0x2218",
      "address-point": "0x2220",
    },
    {
      "name": "toit::OpaqueResource",
      "symbol-address": "0x3328",
      "address-point": "0x3330",
    },
    {
      "name": "toit::VmFinalizerNode",
      "symbol-address": "0x4438",
      "address-point": "0x4440",
    },
  ],
}
