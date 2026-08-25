// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import ar
import encoding.json
import host.directory
import host.file
import io

import ..api as api
import ..description as description
import ..format as format

main:
  tmp := directory.mkdtemp "/tmp/toit-inspector-description-"
  try:
    elf := #[0x7f, 0x45, 0x4c, 0x46, 1, 2, 3, 4]
    inspector-description := description.create fixture-layout elf "fixture.elf"
    description.validate-for-elf inspector-description elf
    expect-equals
        "toit-native-ownership"
        inspector-description["native-ownership"]["format"]
    expect
        inspector-description["native-ownership"]["decoders"].any:
          it["id"] == "toit-event-sources"

    bt-description := description.create bt-layout elf "fixture.elf"
    bt-ownership/Map := bt-description["native-ownership"]
    expect
        bt-ownership["decoders"].any:
          it["id"] == "physical-memory-regions"
    bt-regions/List := bt-ownership["physical-memory-regions"]
    expect-equals 5 bt-regions.size
    expect-equals "static-linked" bt-regions[0]["kind"]
    expect-equals "sdk-reserved" bt-regions[4]["kind"]
    expect-equals "0x3000" bt-regions[4]["start"]
    expect-equals "0x3100" bt-regions[4]["end"]
    description.validate bt-description

    legacy-description := description.create fixture-layout elf "fixture.elf"
    legacy-ownership/Map := legacy-description["native-ownership"]
    legacy-ownership.remove "physical-memory-regions"
    description.validate legacy-description

    malformed-description := description.create fixture-layout elf "fixture.elf"
    malformed-description["native-ownership"]["static-locks"] = [{
      "symbol": 42,
      "component": "logging",
      "kind": "log-lock",
    }]
    expect-throw "INVALID_INSPECTOR_DESCRIPTION":
      description.validate malformed-description

    envelope := envelope-with-description elf inspector-description
    decoded := description.from-envelope envelope
    expect-not-null decoded
    expect-equals
        inspector-description["firmware"]["elf-sha256"]
        decoded["firmware"]["elf-sha256"]

    mismatched := envelope-with-description (elf + #[5]) inspector-description
    expect-throw "INSPECTOR_DESCRIPTION_ELF_MISMATCH":
      description.from-envelope mismatched

    file.write-contents --path="$tmp/firmware.envelope" envelope
    file.write-contents --path="$tmp/dram.bin" #[1, 2, 3, 4]
    file.write-contents --path="$tmp/manifest.json" """
      {
        "target":{"word-size":4,"endianness":"little"},
        "completeness":{"state":"partial"},
        "provenance":{"acquisition":"description-test"},
        "attachments":[{
          "id":"firmware-envelope",
          "kind":"firmware-envelope",
          "file":"firmware.envelope"
        }],
        "regions":[{
          "id":"dram",
          "address":"0x1000",
          "file":"dram.bin"
        }]
      }
      """
    capture := format.import-manifest
        "$tmp/manifest.json"
        "$tmp/device.toitdump"
    expect (capture.metadata.contains "inspector-description")
    expect (capture.metadata.contains "runtime-layout")
    expect-equals
        "firmware-envelope"
        capture.metadata["inspector-description"]["source-envelope-attachment-id"]
    expect-equals
        "firmware-envelope"
        capture.metadata["runtime-layout"]["source-envelope-attachment-id"]
    summary := api.capture-summary capture
    expect-equals
        "firmware-envelope"
        summary["inspector-description"]["source-envelope-attachment-id"]
    loaded := format.load "$tmp/device.toitdump"
    expect-equals capture.id loaded.id
    expect (loaded.metadata.contains "inspector-description")
  finally:
    directory.rmdir --recursive tmp

envelope-with-description elf/ByteArray inspector-description/Map -> ByteArray:
  buffer := io.Buffer
  writer := ar.ArWriter buffer
  writer.add "\$firmware.elf" elf
  writer.add description.ENVELOPE-ENTRY (json.encode inspector-description)
  return buffer.bytes

fixture-layout ::= {
  "format": "toit-runtime-layout",
  "format-version": 1,
  "pointer-size": 4,
  "byte-order": "little",
  "types": {:},
  "symbols": {:},
  "constants": {:},
  "vtables": [],
}

bt-layout ::= {
  "format": "toit-runtime-layout",
  "format-version": 1,
  "pointer-size": 4,
  "byte-order": "little",
  "types": {:},
  "symbols": {
    "_bt_data_start": {"present": true, "address": "0x1000"},
    "_bt_data_end": {"present": true, "address": "0x1100"},
    "_bt_controller_data_start": {"present": true, "address": "0x1200"},
    "_bt_controller_data_end": {"present": true, "address": "0x1280"},
    "_bt_bss_start": {"present": true, "address": "0x2000"},
    "_bt_bss_end": {"present": true, "address": "0x2100"},
    "_bt_controller_bss_start": {"present": true, "address": "0x2200"},
    "_bt_controller_bss_end": {"present": true, "address": "0x2280"},
  },
  "constants": {
    "esp-idf::bt::reserved-region-0-start": 0x3000,
    "esp-idf::bt::reserved-region-0-end": 0x3100,
  },
  "vtables": [],
}
