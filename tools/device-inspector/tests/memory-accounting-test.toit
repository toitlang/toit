// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import io show LITTLE-ENDIAN

import ..memory-accounting as accounting
import ..target as target

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

class TestTarget implements target.Target:
  id/string := "accounting-test"
  regions/List := [
    TestRegion "runtime" "Runtime" 0x1000 8 "ram" "rw",
    TestRegion "external" "External RAM" 0x8000 0x100 "external-ram" "rw",
  ]

  read address/int length/int -> ByteArray:
    if length != 4: throw "TEST_READ_NOT_EXPECTED"
    value := address == 0x1000
        ? 0x8040
        : (address == 0x1004 ? 64 : null)
    if value == null: throw "TEST_READ_NOT_EXPECTED"
    result := ByteArray 4
    LITTLE-ENDIAN.put-uint32 result 0 value
    return result

  allows address/int length/int -> bool:
    return (address >= 0x1000 and address + length <= 0x1008) or
        (address >= 0x8000 and address + length <= 0x8100)

class ValuesTarget implements target.Target:
  id/string := "values-target"
  regions/List := [TestRegion "all" "All" 0x1000 0x8000 "ram" "rw"]
  values/Map

  constructor .values:

  read address/int length/int -> ByteArray:
    if length != 4: throw "TEST_READ_NOT_EXPECTED"
    value := values.get address
    if value == null: throw "TEST_READ_NOT_EXPECTED: $address"
    result := ByteArray 4
    LITTLE-ENDIAN.put-uint32 result 0 value
    return result

  allows address/int length/int -> bool:
    return address >= 0x1000 and address + length <= 0x9000

main:
  expect-equals
      "toit-container:inspector/process:2/1"
      (accounting.process-component 2 1 "inspector")
  expect-equals "toit-process:2/1" (accounting.process-component 2 1)
  allocations := [
    allocation "a" "0x1000" 16,
    allocation "b" "0x2000" 16,
    allocation "c" "0x3000" 8,
    allocation "d" "0x4000" 4,
  ]
  roots := [
    root "ble" "bluetooth" "strong" "0x1004",
    root "net" "networking" "strong" "0x1000",
    root "borrowed" "diagnostics" "borrowed" "0x4000",
  ]
  edges := [{
    "from-allocation-id": "a",
    "target": "0x2008",
    "kind": "owns",
    "strength": "strong",
  }, {
    "from-allocation-id": "b",
    "target": "0x3000",
    "kind": "borrows",
    "strength": "borrowed",
  }]

  complete := accounting.reconcile
      allocations
      roots
      edges
      --allocation-coverage-complete
      --root-coverage-complete
  expect-equals "complete" complete["state"]
  expect-equals 44 complete["summary"]["modeled-bytes"]
  expect-equals 32 complete["summary"]["modeled-reachable-bytes"]
  expect-equals 12 complete["summary"]["modeled-unreachable-bytes"]
  expect-equals 32 complete["summary"]["shared-bytes"]
  expect-equals 12 complete["summary"]["leak-candidate-bytes"]
  expect-equals "shared" complete["allocations"][0]["state"]
  expect-equals ["bluetooth", "networking"]
      complete["allocations"][0]["owners"]
  expect-equals "shared" complete["allocations"][1]["state"]
  expect-equals "leak-candidate" complete["allocations"][2]["state"]
  expect-equals "leak-candidate" complete["allocations"][3]["state"]
  expect-equals 2 complete["components"].size
  expect (complete["components"].every: it["shared-bytes"] == 32)
  expect-equals 1 complete["storage"].size
  expect-equals 44 complete["storage"][0]["bytes"]

  partial := accounting.reconcile allocations roots edges
  expect-equals "partial" partial["state"]
  expect-equals null partial["summary"]["leak-candidate-bytes"]
  expect-equals "unexplained" partial["allocations"][2]["state"]
  expect-equals "not-authoritative"
      partial["coverage"]["leak-classification"]

  payload-allocations := [allocation "external" "0x8000" 64]
  payload-roots := []
  accounting.add-process-external-payloads
      TestTarget
      payload-allocations
      payload-roots
      {
        "external-payload-references": [{
          "object-address": "0x4000",
          "payload-kind": "external-byte-array",
          "address": "0x8010",
          "bytes": 16,
          "captured": true,
          "process-accounted": true,
        }],
      }
      "toit-container:fixture/process:2/1"
  expect-equals 1 payload-roots.size
  expect-equals "0x4000" payload-roots[0]["source-object-address"]
  expect-equals "external-byte-array" payload-roots[0]["payload-kind"]
  expect-equals "external-ram"
      payload-allocations[0]["semantic"][0]["storage"]
  payload-result := accounting.reconcile payload-allocations payload-roots []
  expect-equals "owned" payload-result["allocations"][0]["state"]
  expect-equals
      ["toit-container:fixture/process:2/1"]
      payload-result["allocations"][0]["owners"]

  coverage := accounting.ownership-root-coverage null {
    "unresolved": [],
  }
  expect-equals "decoded" coverage[4]["state"]
  expect-equals "decoded-declared-layouts" coverage[5]["state"]

  gc-allocations := [allocation "metadata" "0x8040" 64]
  gc-roots := []
  gc-result := accounting.add-gc-metadata
      TestTarget
      gc-allocations
      gc-roots
      {
        "symbols": {
          "toit::GcMetadata::singleton_": {
            "present": true,
            "address": "0x1000",
          },
        },
        "types": {
          "toit::GcMetadata": {
            "size": 8,
            "fields": [{"name": "metadata_", "offset": 0, "size": 4},
              {"name": "metadata_size_", "offset": 4, "size": 4}],
          },
        },
      }
  expect-equals "decoded" gc-result["state"]
  expect-equals "0x8040" gc-result["address"]
  expect-equals 1 gc-roots.size
  gc-accounting := accounting.reconcile gc-allocations gc-roots []
  expect-equals ["toit-gc"] gc-accounting["allocations"][0]["owners"]

  spare-allocations := [allocation "spare" "0x8000" 256]
  spare-roots := []
  spare-result := accounting.add-gc-spare-chunk
      (ValuesTarget {0x1000: 0x1100, 0x1104: 0x8000, 0x1108: 0x8100})
      spare-allocations
      spare-roots
      {
        "symbols": {
          "toit::ObjectMemory::spare_chunk_": {
            "present": true,
            "address": "0x1000",
          },
        },
        "types": {
          "toit::Chunk": {
            "size": 12,
            "fields": [{"name": "start_", "offset": 4, "size": 4},
              {"name": "end_", "offset": 8, "size": 4}],
          },
        },
      }
  expect-equals "decoded" spare-result["state"]
  expect-equals 256 spare-result["size"]
  expect-equals 1 spare-roots.size

  allocator-allocations := [allocation "backing" "0x2000" 0x1000]
  allocator-roots := []
  allocator-result := accounting.add-allocator-heap-backing
      allocator-allocations
      allocator-roots
      {
        "state": "complete",
        "heaps": [{
          "index": 1,
          "descriptor": "0x1700",
          "active": false,
          "start": "0x1800",
          "allocated-bytes": 0,
          "free-bytes": 0,
          "overhead-bytes": 0,
        }, {
          "index": 2,
          "descriptor": "0x1800",
          "address": "0x1800",
          "start": "0x2000",
          "allocated-bytes": 0,
          "free-bytes": 3_600,
          "overhead-bytes": 496,
        }],
      }
  expect-equals "decoded" allocator-result["state"]
  expect-equals 1 allocator-result["root-count"]
  expect-equals 1 allocator-roots.size
  expect allocator-allocations[0]["reserved-capacity"]
  expect-equals 0 allocator-allocations[0]["nested-heap-live-bytes"]

  physical-allocations := []
  physical-roots := []
  physical-result := accounting.add-physical-memory-regions
      physical-allocations
      physical-roots
      {
        "state": "complete",
        "heaps": [{
          "active": true,
          "start": "0x2000",
          "end": "0x3000",
        }],
      }
      {
        "decoders": [{"id": "physical-memory-regions", "version": 1}],
        "physical-memory-regions": [{
          "id": "bt-static",
          "component": "bluetooth",
          "kind": "static-linked",
          "storage": "internal-ram",
          "start": "0x1000",
          "end": "0x1100",
          "release-detection": "allocator-registry",
          "evidence": "test-symbols",
        }, {
          "id": "bt-released",
          "component": "bluetooth",
          "kind": "sdk-reserved",
          "storage": "internal-ram",
          "start": "0x2200",
          "end": "0x2300",
          "release-detection": "allocator-registry",
          "evidence": "test-table",
        }],
      }
  expect-equals "decoded" physical-result["state"]
  expect-equals 256 physical-result["owned-bytes"]
  expect-equals 256 physical-result["released-to-allocator-bytes"]
  expect-equals "owned" physical-result["regions"][0]["state"]
  expect-equals "released-to-allocator"
      physical-result["regions"][1]["state"]
  expect-equals 1 physical-allocations.size
  expect-equals 1 physical-roots.size
  physical-accounting := accounting.reconcile
      physical-allocations
      physical-roots
      []
  accounting.apply-physical-memory-coverage
      physical-accounting
      physical-result
  expect-equals 256
      physical-accounting["components"][0]["static-linked-bytes"]
  expect-equals 0
      physical-accounting["components"][0]["sdk-reserved-bytes"]
  expect-equals 0
      physical-accounting["components"][0]["dynamic-and-runtime-bytes"]
  accounting.apply-physical-memory-coverage physical-accounting {
    "category-coverage": {
      "bluetooth": {
        "static-linked": "declared",
        "sdk-reserved": "not-enumerated",
      },
    },
  }
  expect-equals null
      physical-accounting["components"][0]["sdk-reserved-bytes"]

  tags := accounting.allocation-tag-accounting {
    "state": "complete",
    "allocations": [{
      "size": 16,
      "allocator-tag": {"id": 0},
    }, {
      "size": 32,
      "kind": "gc-spare-new-space",
    }],
  }
  expect-equals 16 tags[0]["bytes"]
  expect-equals 1 tags[0]["allocation-count"]

  thread-allocations := [
    allocation "thread" "0x1300" 56,
    allocation "thread-data" "0x1400" 8,
    allocation "tcb" "0x1500" 384,
    allocation "stack" "0x2000" 4096,
  ]
  thread-roots := []
  thread-result := accounting.add-scheduler-thread-roots
      (ValuesTarget {
        0x1000: 0x1100,
        0x1100: 0x1200,
        0x1200: 1,
        0x1204: 0x1310,
        0x1310: 0,
        0x1308: 0x1400,
        0x1400: 0x1500,
        0x1404: 0,
        0x1504: 0x2000,
        0x1508: 0x2fff,
      })
      thread-allocations
      thread-roots
      thread-layout
  expect-equals "decoded-toit-threads" thread-result["state"]
  expect-equals 1 thread-result["threads"].size
  expect-equals 4096 thread-result["threads"][0]["stack-bytes"]
  expect-equals 4 thread-roots.size

  task-tcbs := []
  task-seen := {}
  accounting.collect-freertos-list-tcbs
      (ValuesTarget {
        0x3000: 1,
        0x300c: 0x3100,
        0x3104: 0x3008,
        0x310c: 0x1500,
      })
      freertos-list-layout
      0x3000
      task-tcbs
      task-seen
  expect-equals [0x1500] task-tcbs

thread-layout -> Map:
  return {
    "symbols": {
      "toit::VM::current_": {"present": true, "address": "0x1000"},
    },
    "constants": {
      "toit::SchedulerThread::SCHEDULER_LIST_ELEMENT_OFFSET": 16,
    },
    "types": {
      "toit::VM": type 4 [field "scheduler_" 0],
      "toit::Scheduler": type 8 [
        field "num_threads_" 0,
        field "threads_" 4,
      ],
      "LinkedListElement<toit::SchedulerThread, 1>": type 4 [field "next_" 0],
      "toit::Thread": type 12 [field "handle_" 8],
      "toit::ThreadData": type 8 [
        field "handle" 0,
        field "terminated" 4,
      ],
      "struct tskTaskControlBlock": type 12 [
        field "pxStack" 4,
        field "pxEndOfStack" 8,
      ],
    },
  }

type size/int fields/List -> Map:
  return {"size": size, "fields": fields}

field name/string offset/int -> Map:
  return {"name": name, "offset": offset, "size": 4}

freertos-list-layout -> Map:
  return {
    "types": {
      "struct xLIST": type 20 [
        field "uxNumberOfItems" 0,
        field "xListEnd" 8,
      ],
      "struct xMINI_LIST_ITEM": type 12 [field "pxNext" 4],
      "struct xLIST_ITEM": type 20 [
        field "pxNext" 4,
        field "pvOwner" 12,
      ],
    },
  }

allocation id/string address/string size/int -> Map:
  return {
    "id": id,
    "address": address,
    "size": size,
    "kind": "fixture",
    "storage": "ram",
    "origin-component": "fixture",
  }

root id/string component/string strength/string target/string -> Map:
  return {
    "id": id,
    "component": component,
    "kind": "fixture",
    "strength": strength,
    "target": target,
  }
