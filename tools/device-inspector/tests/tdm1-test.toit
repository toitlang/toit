// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import crypto.crc
import encoding.hex
import encoding.json
import host.directory
import host.file
import io
import io show LITTLE-ENDIAN

import ..api as api
import ..tdm1 as tdm1

main:
  test-golden-frame
  with-tmp-directory: | tmp/string |
    test-complete-with-prefix-noise tmp
    test-binary-prefix-noise tmp
    test-crc-loss-is-explicitly-partial tmp
    test-missing-end-is-partial tmp
    test-broken-region-continuity-is-rejected tmp
    test-crc-loss-invalidates-active-region tmp
    test-content-truncation-keeps-transport-complete tmp
    test-cpu-golden-frame tmp
    test-cpu-evidence-becomes-register-sets tmp
    test-riscv-register-names tmp
    test-malformed-and-duplicate-cpu-frames-are-rejected tmp
    test-semantic-metadata tmp

test-golden-frame:
  encoded := frame
      tdm1.TYPE-REGION
      4
      7
      1
      3
      0x3fc8_0000
      hex.decode "deadbeef"
  expect-equals
      "54444d310204070001000000030000000000c83f04000000deadbeefa225a210"
      (hex.encode encoded)
  parsed := tdm1.scan encoded
  expect-equals 1 parsed.frames.size
  actual/tdm1.Frame := parsed.frames[0]
  expect-equals 4 actual.kind
  expect-equals 0x3fc8_0000 actual.address
  expect-equals (hex.decode "deadbeef") actual.payload

test-complete-with-prefix-noise tmp/string:
  false-sync := frame tdm1.TYPE-REGION 1 3 99 99 0x9000 #[9]
  false-sync[false-sync.size - 1] ^= 1
  info := info-frame --expected-regions=1 --capture-flags=28
  first := frame tdm1.TYPE-REGION 1 5 1 7 0x3ffb_0000 #[1, 2, 3]
  last := frame tdm1.TYPE-REGION 1 6 2 7 0x3ffb_0003 #[4, 5]
  finish := end-frame 3 1 2 5
  capture := tdm1.import-bytes
      ("console noise".to-byte-array + false-sync + info + first + last + finish + false-sync)
      "$tmp/complete.toitdump"
  completeness/Map := capture.metadata["completeness"]
  expect-equals "complete" completeness["state"]
  expect completeness["transport-complete"]
  expect-equals "asynchronous" completeness["capture-mode"]
  expect-equals false completeness["semantic-coherence"]
  expect-equals #[1, 2, 3, 4, 5] (capture.read 0x3ffb_0000 5)
  transport/Map := capture.regions[0].transport
  expect-equals 7 transport["flags"]
  expect-equals 2 transport["chunks"]
  provenance/Map := capture.metadata["provenance"]
  expect-equals 28 provenance["transport"]["info"]["capture-flags"]
  expect-equals 1 provenance["transport"]["diagnostics"]["prefix-candidate-errors"]
  expect-equals 1 provenance["transport"]["diagnostics"]["trailing-candidate-errors"]
  expect-equals
      13 + false-sync.size
      provenance["transport"]["diagnostics"]["prefix-noise-bytes"]

test-binary-prefix-noise tmp/string:
  // UART baud-rate transitions can produce arbitrary bytes. A stray 'T'
  // must not make the sync scanner interpret the following bytes as UTF-8.
  noise := #['T', 0xff, 0xfe, 0xfd]
  info := info-frame --expected-regions=1 --capture-flags=0
  region := frame tdm1.TYPE-REGION 1 3 1 0 0x3ffb_0000 #[42]
  capture := tdm1.import-bytes
      (noise + info + region + (end-frame 2 1 1 1))
      "$tmp/binary-prefix-noise.toitdump"
  expect-equals "complete" capture.metadata["completeness"]["state"]
  expect-equals #[42] (capture.read 0x3ffb_0000 1)
  provenance/Map := capture.metadata["provenance"]
  expect-equals
      noise.size
      provenance["transport"]["diagnostics"]["prefix-noise-bytes"]

test-crc-loss-is-explicitly-partial tmp/string:
  info := info-frame --expected-regions=2 --capture-flags=0
  bad := frame tdm1.TYPE-REGION 1 3 1 0 0x1000 #[9, 9, 9]
  bad[bad.size - 1] ^= 1
  good := frame tdm1.TYPE-REGION 2 3 2 1 0x2000 #[5, 6, 7, 8]
  finish := end-frame 3 2 2 7
  capture := tdm1.import-bytes
      (info + bad + good + finish)
      "$tmp/crc-loss.toitdump"
  completeness/Map := capture.metadata["completeness"]
  expect-equals "partial" completeness["state"]
  expect-not completeness["transport-complete"]
  expect (completeness["reasons"].contains "crc-error")
  expect (completeness["reasons"].contains "non-contiguous-sequence")
  expect (completeness["reasons"].contains "end-chunk-count-mismatch")
  expect-equals 1 capture.regions.size
  expect-equals #[5, 6, 7, 8] (capture.read 0x2000 4)

test-missing-end-is-partial tmp/string:
  info := info-frame --expected-regions=1 --capture-flags=0
  region := frame tdm1.TYPE-REGION 3 3 1 9 0x5000 #[42]
  capture := tdm1.import-bytes
      (info + region)
      "$tmp/missing-end.toitdump"
  expect-equals "partial" capture.metadata["completeness"]["state"]
  expect (capture.metadata["completeness"]["reasons"].contains "missing-end-frame")

test-broken-region-continuity-is-rejected tmp/string:
  info := info-frame --expected-regions=2 --capture-flags=0
  first := frame tdm1.TYPE-REGION 1 1 1 0 0x1000 #[1, 2]
  wrong-address := frame tdm1.TYPE-REGION 1 2 2 0 0x1003 #[3]
  good := frame tdm1.TYPE-REGION 1 3 3 1 0x3000 #[7]
  finish := end-frame 4 2 3 4
  capture := tdm1.import-bytes
      (info + first + wrong-address + good + finish)
      "$tmp/broken-continuity.toitdump"
  expect-equals "partial" capture.metadata["completeness"]["state"]
  expect (capture.metadata["completeness"]["reasons"].contains "non-contiguous-region")
  expect-equals 1 capture.regions.size
  expect-equals 0x3000 capture.regions[0].address

test-crc-loss-invalidates-active-region tmp/string:
  info := info-frame --expected-regions=2 --capture-flags=0
  first := frame tdm1.TYPE-REGION 1 tdm1.FLAG-FIRST 1 0 0x1000 #[1]
  corrupt := frame tdm1.TYPE-REGION 1 0 2 0 0x1001 #[2]
  corrupt[corrupt.size - 1] ^= 1
  last := frame tdm1.TYPE-REGION 1 tdm1.FLAG-LAST 3 0 0x1002 #[3]
  independent := frame
      tdm1.TYPE-REGION
      1
      tdm1.FLAG-FIRST | tdm1.FLAG-LAST
      4
      1
      0x4000
      #[4]
  finish := end-frame 5 2 4 4
  capture := tdm1.import-bytes
      (info + first + corrupt + last + independent + finish)
      "$tmp/crc-active.toitdump"
  expect-equals 1 capture.regions.size
  expect-equals 0x4000 capture.regions[0].address
  reasons/List := capture.metadata["completeness"]["reasons"]
  expect (reasons.contains "region-crosses-sequence-gap")
  expect (reasons.contains "crc-error")

test-content-truncation-keeps-transport-complete tmp/string:
  info := info-frame
      --expected-regions=1
      --capture-flags=tdm1.CAPTURE-FLAG-PSRAM-PRESENT | tdm1.CAPTURE-FLAG-PSRAM-TRUNCATED
  region := frame
      tdm1.TYPE-REGION
      2
      tdm1.FLAG-FIRST | tdm1.FLAG-LAST | tdm1.FLAG-TRUNCATED
      1
      0
      0x3c00_0000
      #[1, 2]
  finish := end-frame 2 1 1 2
  capture := tdm1.import-bytes
      (info + region + finish)
      "$tmp/truncated-psram.toitdump"
  completeness/Map := capture.metadata["completeness"]
  expect-equals "partial" completeness["state"]
  expect completeness["transport-complete"]
  expect (completeness["reasons"].contains "psram-truncated")
  expect (completeness["reasons"].contains "region-truncated")

test-cpu-golden-frame tmp/string:
  cpu-hex := "54444d3104011400010000000100000034120040340000000100000001000000"
  cpu-hex += "0100000002000000040000000100000034120040020000000010fe3f03000000"
  cpu-hex += "250000000001000007000000619c0c96"
  cpu := hex.decode cpu-hex
  info := info-frame
      --expected-regions=1
      --capture-flags=tdm1.CAPTURE-FLAG-CPU-EVIDENCE
  region := frame tdm1.TYPE-REGION 1 3 2 0 0x3ffb_0000 #[1]
  capture := tdm1.import-bytes
      (info + cpu + region + (end-frame 3 1 1 1))
      "$tmp/cpu-golden.toitdump"
  register-set/Map := capture.metadata["register-sets"][0]
  expect-equals 1 register-set["core"]
  expect-equals "0x40001234" register-set["values"]["PC"]
  expect-equals "0x3ffe1000" register-set["values"]["SP"]
  expect-equals "0x00000025" register-set["values"]["STATUS"]
  expect-equals "0x00000007" register-set["values"]["SAR"]

test-cpu-evidence-becomes-register-sets tmp/string:
  capture-flags := tdm1.CAPTURE-FLAG-CPU-EVIDENCE
  capture-flags |= tdm1.CAPTURE-FLAG-PEER-CPU-FROZEN
  capture-flags |= tdm1.CAPTURE-FLAG-PEER-CPU-PARTIAL
  info := info-frame
      --expected-regions=1
      --capture-flags=capture-flags
  calling := cpu-frame
      1
      0
      tdm1.CPU-ARCHITECTURE-XTENSA
      tdm1.CPU-PROVENANCE-CALLING-SAMPLE
      tdm1.FLAG-VOLATILE | tdm1.FLAG-PARTIAL
      0x4000_1234
      [
        [tdm1.REGISTER-PC, 0x4000_1234],
        [tdm1.REGISTER-SP, 0x3ffe_1000],
        [tdm1.REGISTER-STATUS, 0x25],
        [tdm1.REGISTER-XTENSA-SAR, 7],
      ]
  peer := cpu-frame
      2
      1
      tdm1.CPU-ARCHITECTURE-XTENSA
      tdm1.CPU-PROVENANCE-IPC-INTERRUPT
      tdm1.FLAG-VOLATILE | tdm1.FLAG-PARTIAL
      0x4000_5678
      [
        [tdm1.REGISTER-PC, 0x4000_5678],
        [tdm1.REGISTER-SP, 0x3ffe_2000],
        [tdm1.REGISTER-XTENSA-A0 + 5, 0xfeed_beef],
      ]
  region := frame tdm1.TYPE-REGION 1 3 3 0 0x3ffb_0000 #[1]
  capture := tdm1.import-bytes
      (info + calling + peer + region + (end-frame 4 1 1 1))
      "$tmp/cpu-evidence.toitdump"

  register-sets/List := capture.metadata["register-sets"]
  expect-equals 2 register-sets.size
  first/Map := register-sets[0]
  expect-equals "named-uint32-map" first["encoding"]
  expect-equals "uart-tdm1" first["source"]
  expect-equals null (first.get "source-attachment-id")
  expect-equals "0x40001234" first["values"]["PC"]
  expect-equals "0x00000007" first["values"]["SAR"]
  expect first["metadata"]["partial"]
  expect-equals "calling-sample" first["metadata"]["provenance"]
  second/Map := register-sets[1]
  expect-equals "0xfeedbeef" second["values"]["A5"]
  expect-equals "ipc-interrupt" second["metadata"]["provenance"]
  register-page := api.register-sets-page capture 0 100
  expect-equals 2 register-page["total"]
  expect-equals 4 register-page["items"][0]["value-count"]
  expect-equals null (register-page["items"][0].get "source-attachment-id")

test-riscv-register-names tmp/string:
  info := info-frame
      --expected-regions=1
      --capture-flags=tdm1.CAPTURE-FLAG-CPU-EVIDENCE
      --core-count=1
  cpu := cpu-frame
      1
      0
      tdm1.CPU-ARCHITECTURE-RISCV
      tdm1.CPU-PROVENANCE-CALLING-SAMPLE
      tdm1.FLAG-VOLATILE | tdm1.FLAG-PARTIAL
      0x4200_1234
      [
        [tdm1.REGISTER-PC, 0x4200_1234],
        [tdm1.REGISTER-RISCV-X0, 0],
        [tdm1.REGISTER-RISCV-X0 + 31, 0xffff_ffff],
        [tdm1.REGISTER-CAUSE, 11],
      ]
  region := frame tdm1.TYPE-REGION 1 3 2 0 0x4080_0000 #[1]
  capture := tdm1.import-bytes
      (info + cpu + region + (end-frame 3 1 1 1))
      "$tmp/riscv-evidence.toitdump"
  register-set/Map := capture.metadata["register-sets"][0]
  expect-equals "riscv" register-set["architecture"]
  expect-equals "0x00000000" register-set["values"]["X0"]
  expect-equals "0xffffffff" register-set["values"]["X31"]
  expect-equals "0x0000000b" register-set["values"]["CAUSE"]

test-malformed-and-duplicate-cpu-frames-are-rejected tmp/string:
  info := info-frame
      --expected-regions=1
      --capture-flags=tdm1.CAPTURE-FLAG-CPU-EVIDENCE
  malformed := cpu-frame
      1
      0
      tdm1.CPU-ARCHITECTURE-XTENSA
      tdm1.CPU-PROVENANCE-CALLING-SAMPLE
      tdm1.FLAG-PARTIAL
      0x4000_1000
      [
        [tdm1.REGISTER-PC, 0x4000_1000],
        [tdm1.REGISTER-PC, 0x4000_1000],
      ]
  valid := cpu-frame
      2
      0
      tdm1.CPU-ARCHITECTURE-XTENSA
      tdm1.CPU-PROVENANCE-CALLING-SAMPLE
      tdm1.FLAG-PARTIAL
      0x4000_2000
      [[tdm1.REGISTER-PC, 0x4000_2000]]
  duplicate := cpu-frame
      3
      0
      tdm1.CPU-ARCHITECTURE-XTENSA
      tdm1.CPU-PROVENANCE-IPC-INTERRUPT
      tdm1.FLAG-PARTIAL
      0x4000_3000
      [[tdm1.REGISTER-PC, 0x4000_3000]]
  region := frame tdm1.TYPE-REGION 1 3 4 0 0x3ffb_0000 #[1]
  capture := tdm1.import-bytes
      (info + malformed + valid + duplicate + region + (end-frame 5 1 1 1))
      "$tmp/rejected-cpu-evidence.toitdump"
  expect-equals 1 capture.metadata["register-sets"].size
  reasons/List := capture.metadata["completeness"]["reasons"]
  expect (reasons.contains "invalid-cpu-frame")
  expect (reasons.contains "duplicate-cpu-frame")
  diagnostics/Map := capture.metadata["provenance"]["transport"]["diagnostics"]
  expect-equals 2 diagnostics["invalid-cpu-frames"]

test-semantic-metadata tmp/string:
  file.write-contents --path="$tmp/app.snapshot" "snapshot fixture"
  app-image := ByteArray 24 + 8 + 4
  app-image[0] = 0xe9
  app-image[1] = 1
  LITTLE-ENDIAN.put-uint16 app-image 12 0
  LITTLE-ENDIAN.put-uint32 app-image 24 0x3f40_0020
  LITTLE-ENDIAN.put-uint32 app-image 28 4
  app-image.replace 32 #[9, 8, 7, 6]
  file.write-contents --path="$tmp/firmware.bin" app-image
  file.write-contents --path="$tmp/program-layout.json" (json.encode {
    "format": "toit-program-layout",
    "format-version": 2,
    "source-snapshot-sha256":
        "f96c19e0dfa707e3dd68564ea9f6ed3c1a4090fe84057c6118cc29d14ce61d1b",
    "bytecodes-length": 16,
    "bytecodes-sha256":
        "0000000000000000000000000000000000000000000000000000000000000000",
    "opcodes": [],
    "methods": [],
  })
  metadata := {
    "attachments": [
      {
        "id": "app-snapshot",
        "kind": "toit-snapshot",
        "file": "app.snapshot",
        "metadata": {"container": "fixture"},
      },
      {
        "id": "firmware-image",
        "kind": "esp32-app-image",
        "file": "firmware.bin",
      },
    ],
    "memory-images": [
      {
        "attachment-id": "firmware-image",
        "format": "esp32-app-image",
      },
    ],
    "program-layouts": [
      {
        "file": "program-layout.json",
        "snapshot-attachment-id": "app-snapshot",
      },
    ],
  }
  info := info-frame --expected-regions=1 --capture-flags=0
  region := frame tdm1.TYPE-REGION 1 3 1 0 0x3ffb_0000 #[1]
  capture := tdm1.import-bytes
      (info + region + (end-frame 2 1 1 1))
      "$tmp/semantic.toitdump"
      --metadata=metadata
      --metadata-dir=tmp
  expect-equals 2 capture.metadata["attachments"].size
  expect-equals 1 capture.metadata["program-layouts"].size
  expect-equals 2 capture.regions.size
  expect-equals #[9, 8, 7, 6] (capture.read 0x3f40_0020 4)
  expect-equals "flash-mapped-data" capture.regions[1].kind
  expect-equals
      "fixture"
      capture.metadata["program-layouts"][0]["source-container-name"]

info-frame --expected-regions/int --capture-flags/int --core-count/int=2 -> ByteArray:
  payload := words [
    1,
    9,
    3,
    core-count,
    0x55,
    0,
    921_600,
    expected-regions,
    8_388_608,
    4_194_304,
    capture-flags,
  ]
  return frame tdm1.TYPE-INFO 0 0 0 0 0 payload

end-frame sequence/int regions/int chunks/int bytes/int -> ByteArray:
  return frame tdm1.TYPE-END 0 0 sequence 0 0 (words [regions, chunks, bytes])

cpu-frame
    sequence/int core/int architecture/int provenance/int flags/int address/int
    pairs/List
    -> ByteArray:
  payload := io.Buffer
  payload.little-endian.write-uint32 1
  payload.little-endian.write-uint32 core
  payload.little-endian.write-uint32 architecture
  payload.little-endian.write-uint32 provenance
  payload.little-endian.write-uint32 pairs.size
  pairs.do: | pair/List |
    payload.little-endian.write-uint32 pair[0]
    payload.little-endian.write-uint32 pair[1]
  return frame tdm1.TYPE-CPU architecture flags sequence core address payload.bytes

words values/List -> ByteArray:
  result := io.Buffer
  values.do: result.little-endian.write-uint32 it
  return result.bytes

frame
    type/int kind/int flags/int sequence/int region-id/int address/int
    payload/ByteArray
    -> ByteArray:
  body := io.Buffer
  body.write-byte type
  body.write-byte kind
  body.little-endian.write-uint16 flags
  body.little-endian.write-uint32 sequence
  body.little-endian.write-uint32 region-id
  body.little-endian.write-uint32 address
  body.little-endian.write-uint32 payload.size
  body.write payload
  checksum := ByteArray 4
  LITTLE-ENDIAN.put-uint32 checksum 0 (crc.crc32 body.bytes)
  return tdm1.SYNC.to-byte-array + body.bytes + checksum

with-tmp-directory [block]:
  tmp := directory.mkdtemp "/tmp/toit-device-inspector-tdm1-"
  try:
    block.call tmp
  finally:
    directory.rmdir --recursive tmp
