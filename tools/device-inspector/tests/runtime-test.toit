// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import crypto.sha256 as crypto
import host.directory
import io

import ..format as format
import ..inspector as inspector
import ..object-inspection as object-inspection
import ..runtime as runtime
import ..toit-model as toit-model

main:
  tmp := directory.mkdtemp "/tmp/toit-device-inspector-runtime-"
  try:
    content := fixture-memory
    capture := format.write-capture
        "$tmp/runtime.toitdump"
        {
          "platform": "esp32",
          "word-size": 4,
          "endianness": "little",
          "flash-mapped-data-ranges": [{
            "start": "0x2000",
            "end": "0x3000",
            "kind": "flash-mapped-data",
          }],
        }
        {"state": "complete", "semantic-coherence": true}
        {"acquisition": "runtime-test"}
        [{
          "id": "dram",
          "name": "Data RAM",
          "address": 0x1000,
          "kind": "ram",
          "permissions": "rw",
          "content": content,
        }, {
          "id": "program",
          "name": "Program",
          "address": 0x2000,
          "kind": "flash-mapped-data",
          "permissions": "r",
          "content": fixture-program,
        }, {
          "id": "external",
          "name": "External bytes",
          "address": 0x3000,
          "kind": "external-payload",
          "permissions": "rw",
          "content": #[1, 2, 3, 4],
        }, {
          "id": "heap",
          "name": "Heap census fixture",
          "address": 0x4000,
          "kind": "process-heap",
          "permissions": "rw",
          "content": fixture-heap,
        }, {
          "id": "roots",
          "name": "Process root fixture",
          "address": 0x5000,
          "kind": "process-roots",
          "permissions": "rw",
          "content": fixture-roots,
        }]
        --program-layouts=[fixture-program-layout]
    view := toit-model.View
        capture
        (toit-model.Interpretation capture.metadata)
    interpretation-metadata := capture.metadata.copy
    interpretation-metadata["runtime-layout"] = fixture-layout
    decoder := inspector.Inspector
        capture
        (toit-model.Interpretation interpretation-metadata)
    container := runtime.program-container-identity fixture-program-layout
    expect-equals "fixture" container["name"]
    expect-equals "fixture-snapshot" container["snapshot-attachment-id"]

    array := runtime.decode-object view 0x1001
    expect-equals "array" array["type"]
    expect-equals 7 array["class-id"]
    expect-equals 16 array["size"]
    expect array["size-valid"]
    expect-equals 2 array["length"]

    smi := runtime.decode-word view 0x1008
    expect-equals "smi" smi["candidate-kind"]
    expect-equals 42 smi["value"]
    reference := runtime.decode-word view 0x100c
    expect-equals "heap-reference" reference["candidate-kind"]
    expect-equals "0x1010" reference["object-address"]
    flash-reference := runtime.decode-word view (0x1000 + content.size - 4)
    expect-equals "flash" flash-reference["target-storage"]
    expect-equals "flash-mapped-data" flash-reference["target-region"]["kind"]
    uncaptured-flash := {:}
    runtime.add-target-location view uncaptured-flash 0x2f00
    expect-equals "flash" uncaptured-flash["target-storage"]
    expect-equals "0x2f00 (flash, uncaptured)" uncaptured-flash["display"]

    string := runtime.decode-object view 0x1010
    expect-equals "string" string["type"]
    expect-equals 5 string["length"]
    expect-equals "68656c6c6f" string["content-preview"]

    forwarded := runtime.decode-object view 0x1020
    expect-equals "forwarded" forwarded["state"]
    expect-equals "0x1010" forwarded["forwarding-address"]

    task := runtime.decode-object-with-program view 0x1024 0x2000 fixture-layout
    expect-equals "task" task["type"]
    expect-equals 12 task["size"]
    expect task["size-valid"]
    expect-equals "heap-reference" task["stack"]["candidate-kind"]
    expect-equals 6 task["task-id"]["value"]

    external := runtime.decode-object view 0x1030
    expect-equals "byte-array" external["type"]
    expect external["external"]
    expect external["external-content-captured"]
    expect-equals "0x3000" external["external-address"]
    expect-equals "01020304" external["content-preview"]

    stack := runtime.decode-stack view 0x1041 0x2000 fixture-layout
    expect-equals "published" stack["state"]
    expect-equals 8 stack["length"]
    expect-equals 1 stack["top"]
    expect-equals 7 stack["used-slots"]
    expect-equals 72 stack["size"]
    expect-equals 2 stack["frame-count"]
    expect-equals "current" stack["frames"][0]["kind"]
    expect-equals 8 stack["frames"][0]["absolute-bci"]
    expect-equals "operand" stack["frames"][0]["slots"][0]["role"]
    expect-equals 42 stack["frames"][0]["slots"][1]["value"]
    expect-equals "local" stack["frames"][0]["slots"][1]["role"]
    expect-equals "answer" stack["frames"][0]["slots"][1]["name"]
    expect-equals "fixture-main" stack["frames"][0]["method"]["name"]
    expect-equals 4 stack["frames"][0]["method"]["relative-bci"]
    expect-equals "NOP" stack["frames"][0]["method"]["instruction"]["name"]
    expect-equals 1 stack["frames"][0]["method"]["arity"]
    expect-equals 4 stack["frames"][0]["method"]["max-height"]
    expect-equals "fixture.toit" stack["frames"][0]["method"]["source"]["path"]
    expect-equals 1 stack["frames"][0]["argument-slots"].size
    expect-equals 6 stack["frames"][0]["argument-slots"][0]["value"]
    expect-equals
        "parameter"
        stack["frames"][0]["argument-slots"][0]["role"]
    expect-equals "input" stack["frames"][0]["argument-slots"][0]["name"]
    expect-equals
        "callee-argument"
        stack["frames"][0]["argument-slots"][0]["storage-role"]
    expect-equals 0 stack["frames"][0]["argument-slots"][0]["owner-frame-index"]
    expect-equals 1 stack["frames"][0]["argument-slots"][0]["physical-frame-index"]
    expect-equals
        "caller-frame-segment"
        stack["frames"][0]["argument-slots"][0]["physical-storage"]
    expect-equals 0 stack["frames"][0]["local-slots"][0]["physical-frame-index"]
    expect-equals "0x1010" stack["frames"][0]["slots"][0]["object-address"]
    expect-equals "caller" stack["frames"][1]["kind"]
    expect-equals 16 stack["frames"][1]["absolute-bci"]
    expect-equals 6 stack["frames"][1]["slots"][0]["value"]
    expect stack["local-names-available"]

    binary-left := {"role": "operand"}
    binary-right := {"role": "operand"}
    binary-frame := {
      "kind": "current",
      "method": {"instruction": {
        "name": "INVOKE_ADD",
        "absolute-bci": 0,
        "pointer-position": "at-instruction",
      }},
      "operand-slots": [binary-left, binary-right],
    }
    runtime.decorate-current-operand-roles [binary-frame] #[] {:}
    expect-equals "left-operand" binary-left["bytecode-role"]
    expect-equals "right-operand" binary-right["bytecode-role"]
    expect-equals "+" binary-frame["pending-expression"]["operation"]

    discarded := {"role": "operand"}
    runtime.decorate-current-operand-roles [{
      "kind": "current",
      "method": {"instruction": {
        "name": "POP_1",
        "absolute-bci": 0,
        "pointer-position": "at-instruction",
      }},
      "operand-slots": [discarded],
    }] #[] {:}
    expect-equals "discarded-value" discarded["bytecode-role"]

    static-first := {"role": "operand"}
    static-second := {"role": "operand"}
    static-frame := {
      "kind": "current",
      "method": {"instruction": {
        "name": "INVOKE_STATIC",
        "absolute-bci": 0,
        "pointer-position": "at-instruction",
      }},
      "operand-slots": [static-first, static-second],
    }
    runtime.decorate-current-operand-roles
        [static-frame]
        #[0, 0, 0]
        {
          "dispatch-table": [100],
          "methods": [{
            "header-bci": 100,
            "name": "target",
            "kind": "method",
            "arity": 2,
            "parameters": [
              {"index": 0, "name": "receiver", "kind": "this"},
              {"index": 1, "name": "amount", "kind": "explicit"},
            ],
          }],
        }
    expect-equals "pending-parameter" static-first["bytecode-role"]
    expect-equals "receiver" static-first["pending-parameter-name"]
    expect-equals "amount" static-second["pending-parameter-name"]
    expect-equals "target" static-frame["pending-call"]["target"]["name"]

    block-receiver := {
      "role": "operand",
      "block": {"method": {"header-bci": 200}},
    }
    block-argument := {"role": "operand"}
    block-frame := {
      "kind": "current",
      "method": {"instruction": {
        "name": "INVOKE_BLOCK",
        "absolute-bci": 0,
        "pointer-position": "at-instruction",
      }},
      "operand-slots": [block-receiver, block-argument],
    }
    runtime.decorate-current-operand-roles
        [block-frame]
        #[0, 2]
        {"methods": [{
          "header-bci": 200,
          "name": "fixture-block",
          "kind": "block",
          "arity": 2,
          "parameters": [
            {"index": 0, "name": "<block>", "kind": "block-argument"},
            {"index": 1, "name": "value", "kind": "explicit"},
          ],
        }]}
    expect-equals "pending-parameter" block-receiver["bytecode-role"]
    expect-equals "<block>" block-receiver["pending-parameter-name"]
    expect-equals "value" block-argument["pending-parameter-name"]
    expect-equals
        "fixture-block"
        block-frame["pending-call"]["target"]["name"]

    linked-block-method := {
      "name": "protected block",
      "kind": "block",
      "header-bci": 300,
    }
    linked-block-reference := {
      "stack-index": 10,
      "owner-frame-index": 0,
      "physical-frame-index": 1,
      "role": "parameter",
      "block": {
        "stack-index": 15,
        "method": linked-block-method,
      },
    }
    unwind-slots := []
    4.repeat: | index |
      unwind-slots.add {
        "stack-index": 11 + index,
        "owner-frame-index": 1,
        "physical-frame-index": 1,
        "role": "operand",
      }
    linked-block-anchor := {
      "stack-index": 15,
      "owner-frame-index": 1,
      "physical-frame-index": 1,
      "role": "operand",
      "candidate-kind": "smi",
    }
    linked-caller-slots := [linked-block-reference]
    linked-caller-slots.add-all unwind-slots
    linked-caller-slots.add linked-block-anchor
    linked-frames := [{
      "index": 0,
      "slots": [],
      "operand-slots": [],
      "local-or-operand-slots": [],
    }, {
      "index": 1,
      "slots": linked-caller-slots,
      "operand-slots": unwind-slots + [linked-block-anchor],
      "local-or-operand-slots": [],
    }]
    runtime.classify-stack-control-state linked-frames
    expect-equals "block-anchor" linked-block-anchor["role"]
    expect-equals "protected block" linked-block-anchor["name"]
    expect-equals 1 linked-frames[1]["block-anchor-slots"].size
    expect-equals 4 linked-frames[1]["vm-control-slots"].size
    expect-equals
        "unwind-chain"
        linked-frames[1]["vm-control-slots"][0]["control-role"]
    expect-equals
        "unwind-result"
        linked-frames[1]["vm-control-slots"][3]["control-role"]
    expect linked-frames[1]["operand-slots"].is-empty
    process-stacks := runtime.decode-process-stacks-from-runtime
        view
        {
          "semantic-coherence": true,
          "diagnostics": [],
          "process-groups": [{
            "id": 2,
            "address": "0x5000",
            "program": "0x2000",
            "processes": [{
              "id": 1,
              "address": "0x5100",
              "state": "running",
              "priority": 0,
              "object-heap": {
                "address": "0x5200",
                "program": "0x2000",
                "task-reference": "0x5301",
                "task": {
                  "address": "0x5300",
                  "task-id": {"value": 7},
                  "stack": {"object-address": "0x1040"},
                },
              },
            }],
          }],
        }
        fixture-layout
    expect process-stacks["complete"]
    expect-equals 1 process-stacks["process-count"]
    expect-equals 1 process-stacks["decoded-stack-count"]
    expect-equals "decoded" process-stacks["items"][0]["status"]
    expect-equals 7 process-stacks["items"][0]["task"]["id"]
    expect-equals
        "answer"
        process-stacks["items"][0]["stack"]["frames"][0]["slots"][1]["name"]
    globals := runtime.decode-process-globals
        view
        0x5000
        0x2000
        fixture-layout
    expect globals["complete"]
    expect-equals 1 globals["total"]
    expect-equals "fixture-global" globals["items"][0]["qualified-name"]
    expect-equals "ram" globals["items"][0]["target-storage"]
    expect globals["items"][0]["keeps-alive"]
    expect-equals
        2
        globals["program-layout"]["format-version"]
    legacy-layout := fixture-program-layout.copy
    legacy-layout["format-version"] = 1
    legacy-metadata := runtime.program-layout-metadata view legacy-layout
    expect legacy-metadata["global-names-available"]
    expect-not legacy-metadata["frame-variable-names-available"]

    block-slot := {
      "stack-index": 5,
      "address": "0x1064",
      "raw": "0x0204060c",
      "candidate-kind": "smi",
      "value": runtime.BLOCK-SALT + 2,
    }
    block-target := {
      "stack-index": 6,
      "address": "0x1068",
      "raw": "0x00000030",
      "candidate-kind": "smi",
      "value": 24,
      "owner-frame-index": 1,
    }
    block-frames := [{"slots": [block-slot, block-target]}]
    runtime.decorate-stack-values
        view
        0x1040
        8
        block-frames
        []
        0x2000
        fixture-layout
        fixture-program-layout
    expect-equals "block-reference" block-slot["candidate-kind"]
    expect-equals 6 block-slot["block"]["stack-index"]
    expect-equals "fixture-block" block-slot["block"]["method"]["name"]
    published-registers := runtime.classify-stack-register-roots
        view
        0x1040
        0x2000
        fixture-layout
    expect-equals "not-applicable" published-registers["state"]
    expect-equals
        "STACK_STATE_PUBLISHED_IN_HEAP"
        published-registers["reason"]

    active-stack := runtime.decode-stack view 0x1089 0x2000 fixture-layout
    expect-equals "interpreter-owned" active-stack["state"]
    expect-equals null active-stack["top"]
    expect-equals null active-stack["frame-count"]
    expect-equals
        "STACK_TOP_OWNED_BY_ACTIVE_INTERPRETER"
        active-stack["diagnostics"][0]
    active-registers := runtime.classify-stack-register-roots
        view
        0x1088
        0x2000
        fixture-layout
    expect-equals "required" active-registers["state"]
    expect-equals
        "STACK_TOP_OWNED_BY_ACTIVE_INTERPRETER"
        active-registers["reason"]

    census := runtime.heap-range-census
        view
        0x4000
        0x4040
        0x2000
        fixture-layout
        1
        2
    expect census["complete"]
    expect-equals 4 census["object-count"]
    expect-equals 44 census["object-bytes"]
    expect-equals 16 census["free-bytes"]
    expect-equals 60 census["occupied-bytes"]
    expect-equals 4 census["external-payload-bytes"]
    expect-equals 4 census["captured-external-payload-bytes"]
    expect-equals 1 census["external-payload-count"]
    expect-equals 1 census["external-payload-reference-count"]
    expect-equals "0x403c" census["sentinel-address"]
    expect-equals 2 census["items"].size
    expect-equals 3 census["next-offset"]
    expect-equals "FixtureBytes" census["items"][0]["class-name"]
    expect census["items"][1]["class-name"] == "FixtureThing"
    found-free := census["by-type"].any:
      it["type"] == "free-list-region" and it["bytes"] == 16
    expect found-free

    forwarded-census := runtime.heap-range-census
        view
        0x4040
        0x4054
        0x2000
        fixture-layout
    expect forwarded-census["complete"]
    expect-equals 1 forwarded-census["object-count"]
    expect-equals 16 forwarded-census["object-bytes"]
    expect-equals "forwarded" forwarded-census["items"][0]["state"]
    expect-equals "string" forwarded-census["items"][0]["type"]

    edges := runtime.object-edges view 0x4020 0x2000 fixture-layout
    expect-equals "FixtureThing" edges["object"]["class-name"]
    expect-equals 2 edges["total"]
    expect-equals "left" edges["items"][0]["label"]
    expect-equals "0x4000" edges["items"][0]["target"]
    expect-equals "right" edges["items"][1]["label"]
    expect-equals "0x4010" edges["items"][1]["target"]
    expect-throw "PROGRAM_LAYOUT_NOT_AVAILABLE":
      runtime.object-edges view 0x4020 0x2020 fixture-layout

    inspected := object-inspection.inspect-object-graph
        view
        0x2000
        0x4054
        fixture-layout
        [{"start": 0x4054, "end": 0x40b0}]
        8
        20
        20
    expect inspected["complete"]
    expect-equals "0x4054" inspected["root"]
    inspected-root := inspected["objects"].first
    expect-equals "Map" inspected-root["class-name"]
    expect-equals "size_" inspected-root["fields"][0]["name"]
    inspected-map/Map := inspected-root["collection"]
    expect-equals "map" inspected-map["kind"]
    expect-equals 2 inspected-map["length"]
    expect-equals 4 inspected-map["index-capacity"]
    expect-equals 4 inspected-map["backing-capacity"]
    expect-equals 2 inspected-map["entries"].size
    expect-equals 10 inspected-map["entries"][0]["key"]["value"]
    expect-equals
        "FixtureThing"
        inspected-map["entries"][0]["value"]["object"]["class-name"]
    inspected-string := object-inspection.inspect-object-graph
        view
        0x2000
        0x1010
        fixture-layout
        [{"start": 0x1000, "end": 0x1100}]
        0
        1
        1
    expect-equals "hello" inspected-string["objects"][0]["text-preview"]
    expect-throw "PROGRAM_LAYOUT_NOT_AVAILABLE":
      object-inspection.inspect-object-graph
          view
          0x2020
          0x4054
          fixture-layout
          [{"start": 0x4054, "end": 0x40b0}]

    retainers := runtime.direct-retainers
        view
        0x4000
        0x4040
        0x2000
        0x4000
        fixture-layout
    expect retainers["complete"]
    expect-equals 1 retainers["total"]
    expect-equals "0x4020" retainers["items"][0]["retainer"]["address"]
    expect-equals "left" retainers["items"][0]["edge"]["label"]

    path := runtime.retention-path-from-roots
        view
        [{"start": 0x4000, "end": 0x4040}]
        0x2000
        [{
          "kind": "fixture-root",
          "label": "fixture",
          "slot-address": "0x1234",
          "raw": "0x00004021",
          "target": "0x4020",
          "target-captured": true,
          "marked": false,
        }]
        0x4000
        fixture-layout
    expect-equals "found" path["status"]
    expect path["search-complete"]
    expect-equals 1 path["path"]["length"]
    expect-equals "fixture-root" path["path"]["root"]["kind"]
    expect-equals "left" path["path"]["edges"][0]["label"]
    expect-equals "0x4000" path["path"]["edges"][0]["target"]

    graph-roots := [{
      "kind": "fixture-root",
      "label": "fixture",
      "target": "0x4020",
      "strength": "strong",
    }, {
      "kind": "fixture-weak-root",
      "label": "weak",
      "target": "0x4040",
      "strength": "weak",
    }]
    graph := runtime.reachable-from-strong-roots
        view
        [{"start": 0x4000, "end": 0x4054}]
        0x2000
        graph-roots
        fixture-layout
        100
    expect graph["complete"]
    expect-equals 3 graph["decoded-object-count"]
    expect-not (graph["nodes"].contains "0x4040")
    cut-graph := runtime.reachable-from-strong-roots
        view
        [{"start": 0x4000, "end": 0x4054}]
        0x2000
        graph-roots
        fixture-layout
        100
        0x4020
    expect cut-graph["complete"]
    expect-equals 0 cut-graph["decoded-object-count"]

    transitive := runtime.transitive-size-from-target
        view
        [{"start": 0x4000, "end": 0x4054}]
        0x2000
        0x4020
        fixture-layout
        100
    expect-equals "found" transitive["status"]
    expect-equals "inclusive-reachable-closure" transitive["semantics"]
    expect transitive["includes-target"]
    expect transitive["includes-shared-objects"]
    expect transitive["authoritative"]
    expect-equals 3 transitive["transitive-object-count"]
    expect-equals 44 transitive["transitive-object-bytes"]
    expect-equals 4 transitive["transitive-external-payload-bytes"]
    expect-equals 3 transitive["total"]
    outside-transitive := runtime.transitive-size-from-target
        view
        [{"start": 0x4000, "end": 0x4054}]
        0x2000
        0x5000
        fixture-layout
        100
    expect-equals
        "target-not-in-process-heap"
        outside-transitive["status"]
    expect-equals 0 outside-transitive["transitive-object-count"]

    roots := runtime.process-heap-roots view 0x5000 0x2000 fixture-layout
    expect-equals 7 roots["items"].size
    expect-equals "task" roots["items"][0]["kind"]
    expect-equals "fixture-global" roots["items"][1]["label"]
    expect-equals "object-notifier" roots["items"][2]["kind"]
    expect-equals "external-root" roots["items"][3]["kind"]
    expect-equals "runnable-finalizer" roots["items"][4]["kind"]
    expect (roots["items"][4]["label"].ends-with ".key")
    expect (roots["items"][5]["label"].ends-with ".lambda")
    expect-equals "registered-vm-finalizer" roots["items"][6]["kind"]
    expect-equals "weak" roots["items"][6]["strength"]
    expect-equals 6 roots["strong-root-count"]
    expect-equals 1 roots["weak-root-count"]
    expect (roots["decoded-categories"].contains "object-notifiers")
    expect (roots["incomplete-categories"].contains "external-roots")
    expect (roots["decoded-categories"].contains "finalizers")
    found-root-cycle := roots["diagnostics"].any:
      it["code"] == "ROOT_LIST_CYCLE" and it["context"] == "external-root"
    expect found-root-cycle

    search := runtime.search-bytes view "hello".to-byte-array
    expect-equals 1 search["matches"].size
    expect-equals "0x1018" search["matches"][0]["address"]
    symbolized := decoder.symbolize-bci 0x2000 8
    expect-equals "symbolized" symbolized["status"]
    expect-equals "fixture-main" symbolized["method"]["name"]
    expect-equals "0x2000" symbolized["program"]
  finally:
    directory.rmdir --recursive tmp

fixture-memory -> ByteArray:
  result := io.Buffer
  // Array with class id 7 and two elements.
  result.little-endian.write-uint32 (((7 << 5) | 0) << 1)
  result.little-endian.write-uint32 2
  result.little-endian.write-uint32 (42 << 1)
  result.little-endian.write-uint32 0x1011
  // Internal string with class id 8 and five bytes of content.
  result.little-endian.write-uint32 (((8 << 5) | 1) << 1)
  result.little-endian.write-uint16 0xffff
  result.little-endian.write-uint16 5
  result.write "hello".to-byte-array
  result.write-byte 0
  result.write #[0, 0]
  // An object whose header is a forwarding pointer to the string.
  result.little-endian.write-uint32 0x1011
  // A two-field task whose exact size comes from the program class-bits table.
  result.little-endian.write-uint32 (((9 << 5) | 8) << 1)
  result.little-endian.write-uint32 0x1011
  result.little-endian.write-uint32 (6 << 1)
  // External byte array with four bytes at 0x3000.
  result.little-endian.write-uint32 (((10 << 5) | 5) << 1)
  result.little-endian.write-uint32 0xffff_fffb
  result.little-endian.write-uint32 0x3000
  result.little-endian.write-uint32 0
  // Stack with two frame markers and three unnamed value slots.
  result.little-endian.write-uint32 (((11 << 5) | 7) << 1)
  result.little-endian.write-uint32 0
  result.little-endian.write-uint32 8
  result.little-endian.write-uint32 1
  result.little-endian.write-uint32 8
  result.little-endian.write-uint32 0
  4.repeat: result.little-endian.write-uint32 0
  result.little-endian.write-uint32 0
  result.little-endian.write-uint32 0x2041
  result.little-endian.write-uint32 0x2048
  result.little-endian.write-uint32 0x1011
  result.little-endian.write-uint32 (42 << 1)
  result.little-endian.write-uint32 0x2041
  result.little-endian.write-uint32 0x2050
  result.little-endian.write-uint32 (6 << 1)
  // Active stack whose top is owned by the interpreter's native state.
  result.little-endian.write-uint32 (((12 << 5) | 7) << 1)
  result.little-endian.write-uint32 0
  result.little-endian.write-uint32 1
  result.little-endian.write-uint32 0xffff_ffff
  result.little-endian.write-uint32 1
  result.little-endian.write-uint32 0
  4.repeat: result.little-endian.write-uint32 0
  result.little-endian.write-uint32 0
  // A tagged pointer into the flash-mapped program region.
  result.little-endian.write-uint32 0x2001
  return result.bytes

fixture-program -> ByteArray:
  result := ByteArray 128
  io.LITTLE-ENDIAN.put-uint32 result 0 0x2010
  io.LITTLE-ENDIAN.put-uint32 result 4 15
  io.LITTLE-ENDIAN.put-uint32 result 8 0x2040
  io.LITTLE-ENDIAN.put-uint32 result 12 64
  io.LITTLE-ENDIAN.put-uint32 result 20 1
  io.LITTLE-ENDIAN.put-uint16 result (0x10 + 9 * 2) (((12 / 4) << 5) | 8)
  io.LITTLE-ENDIAN.put-uint16 result (0x10 + 13 * 2) (((20 / 4) << 5) | 2)
  io.LITTLE-ENDIAN.put-uint16 result (0x10 + 14 * 2) (((12 / 4) << 5) | 2)
  return result

fixture-heap -> ByteArray:
  result := io.Buffer
  // Array with two elements: 16 bytes.
  result.little-endian.write-uint32 (((7 << 5) | 0) << 1)
  result.little-endian.write-uint32 2
  result.little-endian.write-uint32 (1 << 1)
  result.little-endian.write-uint32 (2 << 1)
  // External byte array with four bytes at 0x3000: 16 bytes.
  result.little-endian.write-uint32 (((10 << 5) | 5) << 1)
  result.little-endian.write-uint32 0xffff_fffb
  result.little-endian.write-uint32 0x3000
  result.little-endian.write-uint32 0
  // Fixed-size instance from program class bits: 12 bytes.
  result.little-endian.write-uint32 (((9 << 5) | 2) << 1)
  result.little-endian.write-uint32 0x4001
  result.little-endian.write-uint32 0x4011
  // A 16-byte free-list region, then the zero sentinel.
  result.little-endian.write-uint32 0xffff_ffd2
  result.little-endian.write-uint32 16
  result.little-endian.write-uint32 0
  result.little-endian.write-uint32 0
  result.little-endian.write-uint32 0
  // A forwarded 16-byte string object and its sentinel.
  result.little-endian.write-uint32 0x1011
  3.repeat: result.little-endian.write-uint32 0xaaaa_aaaa
  result.little-endian.write-uint32 0
  // A two-entry Map with its index, List backing, and backing array.
  result.little-endian.write-uint32 (((13 << 5) | 2) << 1)
  result.little-endian.write-uint32 (2 << 1)
  result.little-endian.write-uint32 (2 << 1)
  result.little-endian.write-uint32 0x4069
  result.little-endian.write-uint32 0x4081
  result.little-endian.write-uint32 (((7 << 5) | 0) << 1)
  result.little-endian.write-uint32 4
  4.repeat: result.little-endian.write-uint32 0
  result.little-endian.write-uint32 (((14 << 5) | 2) << 1)
  result.little-endian.write-uint32 0x408d
  result.little-endian.write-uint32 (4 << 1)
  result.little-endian.write-uint32 (((7 << 5) | 0) << 1)
  result.little-endian.write-uint32 4
  result.little-endian.write-uint32 (10 << 1)
  result.little-endian.write-uint32 0x40a5
  result.little-endian.write-uint32 (20 << 1)
  result.little-endian.write-uint32 0x4001
  result.little-endian.write-uint32 (((9 << 5) | 2) << 1)
  result.little-endian.write-uint32 0x4001
  result.little-endian.write-uint32 0x4011
  return result.bytes

fixture-roots -> ByteArray:
  result := io.Buffer
  // ObjectHeap task and global-variable table pointer.
  result.little-endian.write-uint32 0x4021
  result.little-endian.write-uint32 0x5080
  // Object-notifier list anchor.
  result.little-endian.write-uint32 0x5060
  result.little-endian.write-uint32 0x5060
  // External-root list anchor.
  result.little-endian.write-uint32 0x5070
  result.little-endian.write-uint32 0x5070
  // Runnable, callback, and VM finalizer list anchors.
  result.little-endian.write-uint32 0x5094
  result.little-endian.write-uint32 0
  2.repeat: result.little-endian.write-uint32 0
  result.little-endian.write-uint32 0x50b4
  result.little-endian.write-uint32 0
  // Pad to the native root nodes.
  12.repeat: result.little-endian.write-uint32 0
  // ObjectNotifier element and its object_ slot.
  result.little-endian.write-uint32 0x5008
  result.little-endian.write-uint32 0x5008
  result.little-endian.write-uint32 0x4001
  result.little-endian.write-uint32 0
  // HeapRoot element with an intentional self-cycle and its obj_ slot.
  result.little-endian.write-uint32 0x5070
  result.little-endian.write-uint32 0x5070
  result.little-endian.write-uint32 0x4011
  result.little-endian.write-uint32 0
  // One global-variable slot.
  result.little-endian.write-uint32 0x4001
  3.repeat: result.little-endian.write-uint32 0
  // A ToitFinalizerNode: vtable, list link, key, heap, and lambda.
  result.little-endian.write-uint32 0x9000
  result.little-endian.write-uint32 0
  result.little-endian.write-uint32 0x4001
  result.little-endian.write-uint32 0
  result.little-endian.write-uint32 0x4011
  3.repeat: result.little-endian.write-uint32 0
  // A VmFinalizerNode whose key is a weak root.
  result.little-endian.write-uint32 0x9010
  result.little-endian.write-uint32 0
  result.little-endian.write-uint32 0x4021
  result.little-endian.write-uint32 0
  return result.bytes

fixture-program-layout -> Map:
  bytecodes := fixture-program[0x40..0x40 + 64]
  return {
    "format": "toit-program-layout",
    "format-version": 2,
    "source-snapshot-attachment-id": "fixture-snapshot",
    "source-snapshot-name": "fixture.snapshot",
    "source-container-name": "fixture",
    "source-snapshot-sha256":
        "0000000000000000000000000000000000000000000000000000000000000000",
    "snapshot-uuid": "fixture",
    "sdk-version": "fixture",
    "bytecodes-length": bytecodes.size,
    "bytecodes-sha256": format.bytes-to-hex (crypto.sha256 bytecodes),
    "opcodes": [{"name": "NOP", "size": 1, "description": "No operation"}],
    "globals": [{
      "id": 0,
      "name": "fixture-global",
      "holder-id": null,
      "holder-name": null,
    }],
    "classes": [{
      "id": 7,
      "name": "FixtureArray",
      "path": "fixture.toit",
    }, {
      "id": 9,
      "name": "FixtureThing",
      "path": "fixture.toit",
      "all-fields": ["left", "right"],
    }, {
      "id": 10,
      "name": "FixtureBytes",
      "path": "fixture.toit",
    }, {
      "id": 13,
      "name": "Map",
      "path": "fixture.toit",
      "instance-size": 20,
      "all-fields": ["size_", "index-spaces-left_", "index_", "backing_"],
    }, {
      "id": 14,
      "name": "List_",
      "path": "fixture.toit",
      "instance-size": 12,
      "all-fields": ["array_", "size_"],
    }],
    "methods": [{
      "header-bci": 0,
      "entry-bci": 4,
      "end-bci": 12,
      "bytecode-size": 8,
      "name": "fixture-main",
      "kind": "method",
      "arity": 1,
      "max-height": 4,
      "path": "fixture.toit",
      "positions": [{"relative-bci": 0, "line": 7, "column": 3}],
      "parameters": [{
        "index": 0,
        "name": "input",
        "kind": "explicit",
        "line": 7,
        "column": 14,
      }],
      "locals": [{
        "stack-height": 0,
        "start-bci": 0,
        "end-bci": 8,
        "name": "answer",
        "line": 8,
        "column": 3,
      }],
    }, {
      "header-bci": 12,
      "entry-bci": 16,
      "end-bci": 24,
      "bytecode-size": 8,
      "name": "fixture-caller",
      "kind": "method",
      "arity": 1,
      "max-height": 4,
      "path": "fixture.toit",
      "positions": [{"relative-bci": 0, "line": 3, "column": 1}],
      "parameters": [{
        "index": 0,
        "name": "root",
        "kind": "explicit",
        "line": 3,
        "column": 16,
      }],
      "locals": [],
    }, {
      "header-bci": 24,
      "entry-bci": 28,
      "end-bci": 32,
      "bytecode-size": 4,
      "name": "fixture-block",
      "kind": "block",
      "arity": 1,
      "max-height": 1,
      "path": "fixture.toit",
      "positions": [{"relative-bci": 0, "line": 12, "column": 5}],
      "parameters": [{
        "index": 0,
        "name": "<block>",
        "kind": "block-argument",
      }],
      "locals": [],
    }],
  }

fixture-layout ::= {
  "format": "toit-runtime-layout",
  "format-version": 1,
  "pointer-size": 4,
  "byte-order": "little",
  "types": {
    "toit::Program": {
      "fields": [
        {"name": "class_bits", "offset": 0},
        {"name": "bytecodes", "offset": 8},
        {"name": "global_variables", "offset": 16},
      ],
    },
    "toit::Program::Table<toit::Object*>": {
      "fields": [{"name": "length_", "offset": 4}],
    },
    "toit::ObjectHeap": {
      "fields": [
        {"name": "task_", "offset": 0},
        {"name": "global_variables_", "offset": 4},
        {"name": "object_notifiers_", "offset": 8},
        {"name": "external_roots_", "offset": 16},
        {"name": "runnable_finalizers_", "offset": 24},
        {"name": "registered_callback_finalizers_", "offset": 32},
        {"name": "registered_vm_finalizers_", "offset": 40},
      ],
    },
    "DoubleLinkedListElement<toit::ObjectNotifier, 1>": {
      "fields": [{"name": "next_", "offset": 0}],
    },
    "toit::ObjectNotifier": {
      "fields": [{"name": "object_", "offset": 8}],
    },
    "DoubleLinkedListElement<toit::HeapRoot, 1>": {
      "fields": [{"name": "next_", "offset": 0}],
    },
    "toit::HeapRoot": {
      "fields": [{"name": "obj_", "offset": 8}],
    },
    "LinkedListElement<toit::FinalizerNode, 1>": {
      "fields": [{"name": "next_", "offset": 0}],
    },
    "toit::FinalizerNode": {
      "fields": [{"name": "key_", "offset": 8}],
    },
    "toit::CallableFinalizerNode": {
      "fields": [{"name": "lambda_", "offset": 16}],
    },
    "toit::List<unsigned short>": {
      "fields": [
        {"name": "data_", "offset": 0},
        {"name": "length_", "offset": 4},
      ],
    },
    "toit::List<unsigned char>": {
      "fields": [
        {"name": "data_", "offset": 0},
        {"name": "length_", "offset": 4},
      ],
    },
  },
  "symbols": {},
  "vtables": [{
    "name": "toit::ToitFinalizerNode",
    "address-point": "0x9000",
  }, {
    "name": "toit::VmFinalizerNode",
    "address-point": "0x9010",
  }],
  "constants": {
    "toit::Stack::HEADER_SIZE": 40,
    "toit::Stack::LENGTH_OFFSET": 8,
    "toit::Stack::TOP_OFFSET": 12,
    "toit::Stack::TRY_TOP_OFFSET": 16,
    "toit::Stack::PENDING_STACK_CHECK_METHOD_OFFSET": 20,
    "toit::ObjectNotifier::HEAP_LIST_ELEMENT_OFFSET": 0,
    "toit::HeapRoot::HEAP_LIST_ELEMENT_OFFSET": 0,
    "toit::FinalizerNode::HEAP_LIST_ELEMENT_OFFSET": 4,
  },
}
