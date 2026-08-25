// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.json
import expect show *
import host.directory
import host.file
import io

import ar
import ..description as description
import ..qemu-acquire
import ..qmp

main:
  test-qmp-client
  test-target-description-parsing
  test-hmp-register-parsing
  test-psram-region-classification
  test-runtime-layout-from-envelope

test-qmp-client:
  input := """
    {"QMP":{"version":{}}}
    {"return":{},"id":1}
    {"event":"STOP"}
    {"return":{"status":"paused"},"id":2}
    """.to-byte-array
  output := io.Buffer
  client := Client (io.Reader input) output
  result/Map := client.execute "query-status"
  expect-equals "paused" result["status"]
  lines := output.bytes.to-string.trim.split "\n"
  expect-equals 2 lines.size
  capabilities/Map := json.decode lines[0].to-byte-array
  query/Map := json.decode lines[1].to-byte-array
  expect-equals "qmp_capabilities" capabilities["execute"]
  expect-equals 1 capabilities["id"]
  expect-equals "query-status" query["execute"]
  expect-equals 2 query["id"]

test-target-description-parsing:
  target := """
    <target xmlns:xi="http://www.w3.org/2001/XInclude">
      <architecture>xtensa</architecture>
      <xi:include href="core.xml"/>
    </target>
    """
  expect-equals ["core.xml"] (xml-includes target)
  expect-equals "xtensa" (architecture-from-documents {"target.xml": target})
  threads := threads-from-xml """
    <threads>
      <thread id="p1.2" core="1"/>
      <thread id="p1.1" core="0"/>
    </threads>
    """
  expect-equals 2 threads.size
  expect-equals "p1.2" threads[0]["thread-id"]
  expect-equals 1 threads[0]["core"]
  expect-equals 0 threads[1]["core"]

test-hmp-register-parsing:
  output := hmp-core 0 0x4000_0400
  output += hmp-core 1 0x4000_0500
  cpus := [
    {
      "cpu-index": 0,
      "thread-id": 100,
      "target": "xtensa",
      "qom-path": "/cpu0",
    },
    {
      "cpu-index": 1,
      "thread-id": 101,
      "target": "xtensa",
      "qom-path": "/cpu1",
    },
  ]
  registers := capture-named-registers output cpus
  expect-equals [0, 1] (registers.map: it["core"])
  expect-equals "0x40000400" registers[0]["values"]["PC"]
  expect-equals "0x00000010" registers[1]["values"]["A15"]
  expect-equals "qemu-qmp-hmp-validated" registers[1]["source"]

test-psram-region-classification:
  expect (is-psram-region {"kind": "external-ram"})
  expect (is-psram-region {"kind": "psram"})
  expect-not (is-psram-region {"kind": "ram"})

test-runtime-layout-from-envelope:
  tmp := directory.mkdtemp "/tmp/toit-qemu-layout-"
  try:
    elf := #[1, 2, 3, 4]
    layout := {
      "format": "toit-runtime-layout",
      "format-version": 1,
      "pointer-size": 4,
      "byte-order": "little",
      "types": {:},
      "symbols": {:},
      "constants": {:},
      "vtables": [],
    }
    inspector-description := description.create layout elf "fixture.elf"
    buffer := io.Buffer
    writer := ar.ArWriter buffer
    writer.add "\$firmware.elf" elf
    writer.add description.ENVELOPE-ENTRY (json.encode inspector-description)
    file.write-contents --path="$tmp/firmware.envelope" buffer.bytes
    result := runtime-layout-from-manifest {
      "attachments": [{
        "id": "firmware-envelope",
        "kind": "firmware-envelope",
        "file": "firmware.envelope",
      }],
    } tmp
    expect-equals "toit-runtime-layout" result["format"]
  finally:
    directory.rmdir --recursive tmp

hmp-core core/int pc/int -> string:
  result := "\r\nCPU#$core\r\nPC=$(hex8 pc)\r\nPS=0000001f"
  16.repeat:
    result += " A$(two-digits it)=$(hex8 (it + core))"
  return result + "\r\n"

hex8 value/int -> string:
  result := value.to-string --radix=16
  return "00000000"[..8 - result.size] + result
