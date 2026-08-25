// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import encoding.base64
import encoding.json
import host.directory
import host.file

import ..api as api
import ..format as format

main:
  tmp := directory.mkdtemp "/tmp/toit-device-inspector-"
  try:
    file.write-contents --path="$tmp/dram.bin" #[0x10, 0x20, 0x30, 0x40]
    file.write-contents --path="$tmp/firmware.elf" "ELF fixture"
    file.write-contents --path="$tmp/app.snapshot" "snapshot fixture"
    file.write-contents --path="$tmp/program-layout.json" """
      {
        "format":"toit-program-layout",
        "format-version":2,
        "source-snapshot-sha256":"f96c19e0dfa707e3dd68564ea9f6ed3c1a4090fe84057c6118cc29d14ce61d1b",
        "bytecodes-length":16,
        "bytecodes-sha256":"0000000000000000000000000000000000000000000000000000000000000000",
        "opcodes":[],
        "methods":[]
      }
      """
    file.write-contents --path="$tmp/runtime-layout.json" """
      {"format":"toit-runtime-layout","format-version":1,"pointer-size":4,"byte-order":"little","types":{},"symbols":{}}
      """
    file.write-contents --path="$tmp/manifest.json" """
      {
        "target":{"chip":"esp32","word-size":4,"endianness":"little"},
        "completeness":{"state":"partial","missing-regions":["psram"]},
        "provenance":{
          "acquisition":"test-fixture",
          "capture-mode":"runtime-checkpoint",
          "semantic-coherence":false,
          "capture-point":{"name":"mark-complete","id":7,"context":"0x1234"}
        },
        "capture-scope":{"kind":"process-group","selected":{"id":7}},
        "attachments":[
          {"id":"firmware-elf","kind":"firmware-elf","file":"firmware.elf"},
          {"id":"app-snapshot","kind":"toit-snapshot","file":"app.snapshot","metadata":{"container":"app"}}
        ],
        "runtime-layout":{"file":"runtime-layout.json","elf-attachment-id":"firmware-elf"},
        "program-layouts":[{"file":"program-layout.json","snapshot-attachment-id":"app-snapshot"}],
        "register-sets":[
          {
            "core":0,
            "thread-id":"p1.1",
            "architecture":"xtensa",
            "encoding":"gdb-remote-register-packet",
            "data":"01020304",
            "layout-attachment-id":"firmware-elf"
          },
          {
            "core":1,
            "thread-id":"p1.2",
            "architecture":"xtensa",
            "encoding":"named-uint32-map",
            "values":{"PC":"0x40000400","A00":"0x1"},
            "source-attachment-id":"firmware-elf"
          }
        ],
        "regions":[{"id":"dram","address":"0x3ffb0000","file":"dram.bin"}]
      }
      """
    capture := format.import-manifest "$tmp/manifest.json" "$tmp/test.toitdump"
    expect-equals 1 capture.regions.size
    expect-equals "partial" capture.metadata["completeness"]["state"]
    expect-equals 7 capture.metadata["capture-scope"]["selected"]["id"]
    expect-equals "runtime-checkpoint" capture.observation["capture-mode"]
    expect-equals
        "mark-complete"
        capture.observation["runtime-checkpoint"]["name"]
    expect-equals #[0x20, 0x30] (capture.read 0x3ffb0001 2)

    loaded := format.load "$tmp/test.toitdump"
    expect-equals capture.id loaded.id
    expect-equals "process-group" (api.capture-summary loaded)["capture-scope"]["kind"]
    expect-equals 1 (api.capture-summary loaded)["program-layout-count"]
    expect
        ((api.discovery loaded)["capabilities"].contains
            "process-stack-discovery")
    expect
        ((api.discovery loaded)["capabilities"].contains
            "program-bci-symbolization")
    expect
        ((api.discovery loaded)["capabilities"].contains
            "component-memory-accounting")
    expect-equals
        "/api/v1/captures/$(loaded.id)/process-stacks"
        (api.capture-summary loaded)["links"]["process-stacks"]
    expect-equals
        "/api/v1/captures/$(loaded.id)/process-variables"
        (api.capture-summary loaded)["links"]["process-variables"]
    expect-equals
        "/api/v1/captures/$(loaded.id)/symbolize{?program,bci}"
        (api.capture-summary loaded)["links"]["symbolize-bci"]
    expect-equals
        "/api/v1/captures/$(loaded.id)/memory-accounting"
        (api.capture-summary loaded)["links"]["memory-accounting"]
    expect
        ((api.openapi)["paths"].contains
            "/api/v1/captures/{captureId}/process-stacks")
    expect
        ((api.openapi)["paths"].contains
            "/api/v1/captures/{captureId}/process-variables")
    expect
        ((api.openapi)["paths"].contains
            "/api/v1/captures/{captureId}/symbolize")
    expect
        ((api.openapi)["paths"].contains
            "/api/v1/captures/{captureId}/memory-accounting")
    expect-equals 2 loaded.metadata["attachments"].size
    expect-equals "01020304" loaded.metadata["register-sets"][0]["data"]
    expect-equals "0x00000001" loaded.metadata["register-sets"][1]["values"]["A00"]
    expect-equals "firmware-elf" loaded.metadata["runtime-layout"]["source-elf-attachment-id"]
    expect-equals loaded.metadata["attachments"][0]["sha256"] loaded.metadata["runtime-layout"]["source-elf-sha256"]
    expect-equals 1 loaded.metadata["program-layouts"].size
    expect-equals 2 loaded.metadata["program-layouts"][0]["format-version"]
    expect-equals
        "app-snapshot"
        loaded.metadata["program-layouts"][0]["source-snapshot-attachment-id"]
    expect-equals
        "app.snapshot"
        loaded.metadata["program-layouts"][0]["source-snapshot-name"]
    expect-equals
        "app"
        loaded.metadata["program-layouts"][0]["source-container-name"]
    second := format.import-manifest "$tmp/manifest.json" "$tmp/test-2.toitdump"
    expect-equals capture.id second.id
    program-layout := (file.read-contents "$tmp/program-layout.json").to-string
    file.write-contents
        --path="$tmp/program-layout.json"
        (program-layout.replace --all
            "\"format-version\":2"
            "\"format-version\":1")
    legacy := format.import-manifest "$tmp/manifest.json" "$tmp/legacy.toitdump"
    expect-equals 1 legacy.metadata["program-layouts"][0]["format-version"]
    file.write-contents --path="$tmp/program-layout.json" program-layout
    file.write-contents
        --path="$tmp/program-layout.json"
        (program-layout.replace --all
            "f96c19e0dfa707e3dd68564ea9f6ed3c1a4090fe84057c6118cc29d14ce61d1b"
            "1111111111111111111111111111111111111111111111111111111111111111")
    expect-throw "PROGRAM_LAYOUT_SNAPSHOT_MISMATCH":
      format.import-manifest "$tmp/manifest.json" "$tmp/mismatched.toitdump"
    expect-equals
        (json.stringify (api.capture-detail capture))
        (json.stringify (api.capture-detail loaded))
    page := api.regions-page loaded 0 100
    expect-equals "0x3ffb0000" page["items"][0]["address"]
    memory := api.memory-read loaded 0x3ffb0000 4
    expect-equals (base64.encode #[0x10, 0x20, 0x30, 0x40]) memory["data"]
    expect-throw "ADDRESS_NOT_CAPTURED": loaded.read 0x3ffaffff 1
    expect-throw "INVALID_LENGTH": api.memory-read loaded 0x3ffb0000 (api.MAX-MEMORY-READ + 1)
    attachments := api.attachments-page loaded 0 100
    expect-equals 2 attachments["total"]
    expect-equals "firmware-elf" (api.attachment-detail loaded "firmware-elf")["kind"]
    registers := api.register-sets-page loaded 0 100
    expect-equals 2 registers["total"]
    expect-equals null (registers["items"][0].get "data")
    expect-equals "01020304" (api.register-set-detail loaded "core-0")["data"]
    expect-equals 2 registers["items"][1]["value-count"]

    corrupted := file.read-contents "$tmp/test.toitdump"
    corrupted[corrupted.size - 1] ^= 0xff
    file.write-contents --path="$tmp/corrupted.toitdump" corrupted
    expect-throw "DUMP_CHECKSUM_MISMATCH": format.load "$tmp/corrupted.toitdump"
  finally:
    directory.rmdir --recursive tmp
