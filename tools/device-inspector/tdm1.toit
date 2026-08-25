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

import crypto.crc
import encoding.json
import fs
import host.file
import io
import io show LITTLE-ENDIAN

import .format as format
import .esp32-image as esp32-image

SYNC ::= "TDM1"
HEADER-SIZE ::= 20
FRAME-OVERHEAD ::= 28
MAX-PAYLOAD-SIZE ::= 1_024

TYPE-INFO ::= 1
TYPE-REGION ::= 2
TYPE-END ::= 3
TYPE-CPU ::= 4

FLAG-FIRST ::= 1
FLAG-LAST ::= 2
FLAG-VOLATILE ::= 4
FLAG-TRUNCATED ::= 8
FLAG-PARTIAL ::= 16
STRUCTURAL-FLAGS ::= FLAG-FIRST | FLAG-LAST
CPU-FLAGS ::= FLAG-VOLATILE | FLAG-PARTIAL

CAPTURE-FLAG-PSRAM-PRESENT ::= 1
CAPTURE-FLAG-PSRAM-TRUNCATED ::= 2
CAPTURE-FLAG-CURRENT-STACK-VOLATILE ::= 4
CAPTURE-FLAG-PERIPHERALS-RUNNING ::= 8
CAPTURE-FLAG-PEER-CPU-FROZEN ::= 16
CAPTURE-FLAG-CPU-EVIDENCE ::= 32
CAPTURE-FLAG-PEER-CPU-PARTIAL ::= 64

CPU-ARCHITECTURE-XTENSA ::= 1
CPU-ARCHITECTURE-RISCV ::= 2

CPU-PROVENANCE-CALLING-SAMPLE ::= 1
CPU-PROVENANCE-IPC-INTERRUPT ::= 2

REGISTER-PC ::= 1
REGISTER-SP ::= 2
REGISTER-STATUS ::= 3
REGISTER-CAUSE ::= 4
REGISTER-FAULT-ADDRESS ::= 5
REGISTER-XTENSA-SAR ::= 0x100
REGISTER-XTENSA-A0 ::= 0x110
REGISTER-RISCV-X0 ::= 0x200

class Frame:
  type/int
  kind/int
  flags/int
  sequence/int
  region-id/int
  address/int
  payload/ByteArray

  constructor --.type --.kind --.flags --.sequence --.region-id --.address
      --.payload:

class ScanResult:
  frames/List
  diagnostics/Map

  constructor --.frames --.diagnostics:

class RegionBuilder:
  region-id/int
  kind/int
  flags/int := ?
  address/int
  next-address/int := ?
  chunks/int := 0
  invalid/bool := false
  bytes/io.Buffer := io.Buffer

  constructor frame/Frame:
    region-id = frame.region-id
    kind = frame.kind
    flags = frame.flags
    address = frame.address
    next-address = frame.address

  add frame/Frame -> none:
    flags |= frame.flags
    bytes.write frame.payload
    chunks++
    next-address += frame.payload.size

import-stream
    input-path/string
    output-path/string
    --metadata-path/string?=null
    -> format.Capture:
  metadata/Map? := null
  metadata-dir := "."
  if metadata-path:
    metadata = json.decode (file.read-contents metadata-path)
    metadata-dir = fs.dirname metadata-path
  return import-bytes
      (file.read-contents input-path)
      output-path
      --metadata=metadata
      --metadata-dir=metadata-dir

import-bytes
    stream/ByteArray
    output-path/string
    --metadata/Map?=null
    --metadata-dir/string="."
    -> format.Capture:
  scan := scan stream
  frames := scan.frames
  diagnostics := scan.diagnostics
  reasons := []
  info/Map? := null
  end/Map? := null
  region-inputs := []
  register-inputs := []
  seen-region-ids := {}
  seen-cpu-cores := {}
  active/RegionBuilder? := null
  last-sequence/int? := null
  observed-region-frames := 0
  observed-region-bytes := 0
  observed-region-ends := 0
  saw-end := false

  frames.do: | frame/Frame |
    if last-sequence == null:
      if frame.sequence != 0:
        increment diagnostics "sequence-errors"
        add-reason reasons "sequence-does-not-start-at-zero"
    else if frame.sequence != last-sequence + 1:
      increment diagnostics "sequence-errors"
      add-reason reasons "non-contiguous-sequence"
      if active:
        active.invalid = true
        add-reason reasons "region-crosses-sequence-gap"
      if frame.sequence <= last-sequence:
        increment diagnostics "invalid-frames"
        continue.do
    last-sequence = frame.sequence

    if saw-end:
      increment diagnostics "invalid-frames"
      add-reason reasons "frame-after-end"
      continue.do

    if frame.type == TYPE-INFO:
      if frame.payload.size != 44 or frame.kind != 0 or frame.flags != 0 or
          frame.region-id != 0 or frame.address != 0 or info:
        increment diagnostics "invalid-frames"
        add-reason reasons "invalid-info-frame"
        continue.do
      info = decode-info frame.payload
      if info["format-version"] != 1:
        add-reason reasons "unsupported-wire-version"
      continue.do

    if frame.type == TYPE-REGION:
      observed-region-frames++
      observed-region-bytes += frame.payload.size
      if (frame.flags & FLAG-LAST) != 0: observed-region-ends++
      if not info: add-reason reasons "region-before-info"
      first := (frame.flags & FLAG-FIRST) != 0
      last := (frame.flags & FLAG-LAST) != 0
      if first:
        if active:
          increment diagnostics "invalid-regions"
          add-reason reasons "unterminated-region"
        active = RegionBuilder frame
        if seen-region-ids.contains frame.region-id:
          active.invalid = true
          add-reason reasons "duplicate-region-id"
        if frame.kind < 1 or frame.kind > 4 or frame.payload.is-empty:
          active.invalid = true
          add-reason reasons "invalid-region-frame"
      else if not active:
        increment diagnostics "invalid-frames"
        add-reason reasons "region-without-first"
        continue.do

      if frame.region-id != active.region-id or frame.kind != active.kind or
          frame.address != active.next-address or frame.payload.is-empty or
          (frame.flags & ~STRUCTURAL-FLAGS) !=
              (active.flags & ~STRUCTURAL-FLAGS):
        active.invalid = true
        add-reason reasons "non-contiguous-region"
      active.add frame
      if last:
        if active.invalid:
          increment diagnostics "invalid-regions"
        else:
          seen-region-ids.add active.region-id
          region-inputs.add (region-input active)
        active = null
      continue.do

    if frame.type == TYPE-CPU:
      if active:
        active.invalid = true
        increment diagnostics "invalid-frames"
        increment diagnostics "invalid-cpu-frames"
        add-reason reasons "cpu-frame-inside-region"
        continue.do
      if not info:
        increment diagnostics "invalid-frames"
        increment diagnostics "invalid-cpu-frames"
        add-reason reasons "cpu-before-info"
        continue.do
      cpu-input/Map? := null
      exception := catch: cpu-input = decode-cpu-register-input frame
      if exception:
        increment diagnostics "invalid-frames"
        increment diagnostics "invalid-cpu-frames"
        add-reason reasons "invalid-cpu-frame"
        continue.do
      core/int := cpu-input["core"]
      if core >= info["core-count"]:
        increment diagnostics "invalid-frames"
        increment diagnostics "invalid-cpu-frames"
        add-reason reasons "invalid-cpu-core"
        continue.do
      if seen-cpu-cores.contains core:
        increment diagnostics "invalid-frames"
        increment diagnostics "invalid-cpu-frames"
        add-reason reasons "duplicate-cpu-frame"
        continue.do
      seen-cpu-cores.add core
      register-inputs.add cpu-input
      continue.do

    if frame.type == TYPE-END:
      saw-end = true
      if active:
        increment diagnostics "invalid-regions"
        add-reason reasons "unterminated-region"
        active = null
      if frame.payload.size != 12 or frame.kind != 0 or frame.flags != 0 or
          frame.region-id != 0 or frame.address != 0 or end:
        increment diagnostics "invalid-frames"
        add-reason reasons "invalid-end-frame"
        continue.do
      end = decode-end frame.payload
      continue.do

    increment diagnostics "invalid-frames"
    add-reason reasons "unknown-frame-type"

  if active:
    increment diagnostics "invalid-regions"
    add-reason reasons "unterminated-region"
  if not info: add-reason reasons "missing-info-frame"
  if not end: add-reason reasons "missing-end-frame"
  if diagnostics["crc-errors"] > 0: add-reason reasons "crc-error"
  if diagnostics["framing-errors"] > 0: add-reason reasons "framing-error"
  if diagnostics["interframe-noise-bytes"] > 0:
    add-reason reasons "interframe-noise"

  if info and info["expected-region-count"] != region-inputs.size:
    add-reason reasons "info-region-count-mismatch"
  if info:
    has-cpu-flag :=
        (info["capture-flags"] & CAPTURE-FLAG-CPU-EVIDENCE) != 0
    if has-cpu-flag != (not register-inputs.is-empty):
      add-reason reasons "cpu-evidence-flag-mismatch"
  if end:
    if end["region-count"] != observed-region-ends:
      add-reason reasons "end-region-count-mismatch"
    if end["chunk-count"] != observed-region-frames:
      add-reason reasons "end-chunk-count-mismatch"
    if end["byte-count"] != observed-region-bytes:
      add-reason reasons "end-byte-count-mismatch"
    if end["region-count"] != region-inputs.size:
      add-reason reasons "decoded-region-count-mismatch"
  transport-complete := reasons.is-empty
  if info and (info["capture-flags"] & CAPTURE-FLAG-PSRAM-TRUNCATED) != 0:
    add-reason reasons "psram-truncated"
  region-inputs.do: | input/Map |
    transport/Map := input["transport"]
    if (transport["flags"] & FLAG-TRUNCATED) != 0:
      add-reason reasons "region-truncated"

  completeness := {
    "state": reasons.is-empty ? "complete" : "partial",
    "transport-complete": transport-complete,
    "capture-mode": "asynchronous",
    "semantic-coherence": false,
    "end-frame-present": end != null,
    "reasons": reasons,
    "received-regions": region-inputs.size,
  }
  if info: completeness["expected-regions"] = info["expected-region-count"]

  provenance := {
    "acquisition": "uart-tdm1",
    "capture-mode": "asynchronous",
    "semantic-coherence": false,
    "transport": {
      "wire-format": SYNC,
      "wire-version": info ? info["format-version"] : null,
      "info": info,
      "end": end,
      "diagnostics": diagnostics,
    },
  }
  target := info
      ? {
        "platform": "esp32",
        "chip-model": info["chip-model"],
        "chip-revision": info["chip-revision"],
        "cores": info["core-count"],
        "features": info["chip-features"],
        "word-size": 4,
        "endianness": "little",
      }
      : {
        "platform": "esp32",
        "word-size": 4,
        "endianness": "little",
      }
  attachment-inputs/List := metadata
      ? metadata.get "attachments" --if-absent=: []
      : []
  attachments := format.import-attachments metadata-dir attachment-inputs
  memory-image-ranges := []
  if metadata:
    memory-image-ranges = add-memory-image-regions
        metadata-dir
        metadata.get "memory-images" --if-absent=: []
        attachment-inputs
        attachments
        region-inputs
  if not memory-image-ranges.is-empty:
    target["flash-mapped-data-ranges"] = memory-image-ranges
  register-sets := format.normalize-register-sets register-inputs attachments
  inspector-description := format.import-envelope-description
      metadata-dir
      attachment-inputs
      attachments
  legacy-runtime-layout := format.import-runtime-layout
      metadata-dir
      (metadata ? metadata.get "runtime-layout" : null)
      attachments
  runtime-layout/Map? := inspector-description
      ? inspector-description["runtime-layout"]
      : legacy-runtime-layout
  if inspector-description and legacy-runtime-layout and
      not format.runtime-layouts-equivalent
          inspector-description["runtime-layout"]
          legacy-runtime-layout:
    throw "INSPECTOR_DESCRIPTION_RUNTIME_LAYOUT_MISMATCH"
  program-layout-inputs/List := []
  if metadata:
    program-layout-inputs = metadata.get "program-layouts" --if-absent=: []
  program-layouts := format.import-program-layouts
      metadata-dir
      program-layout-inputs
      attachments
  capture-scope := format.normalize-capture-scope
      (metadata ? metadata.get "capture-scope" : null)
  return format.write-capture
      output-path
      target
      completeness
      provenance
      region-inputs
      --attachments=attachments
      --register-sets=register-sets
      --inspector-description=inspector-description
      --runtime-layout=runtime-layout
      --program-layouts=program-layouts
      --capture-scope=capture-scope

add-memory-image-regions
    metadata-dir/string
    image-inputs/List
    attachment-inputs/List
    attachments/List
    region-inputs/List
    -> List:
  ranges := []
  image-inputs.do: | image-input/Map |
    if image-input["format"] != "esp32-app-image":
      throw "UNSUPPORTED_MEMORY_IMAGE_FORMAT"
    attachment-id/string := image-input["attachment-id"]
    attachment/Map? := null
    attachment-input/Map? := null
    attachments.do: | candidate/Map |
      if candidate["id"] == attachment-id: attachment = candidate
    attachment-inputs.do: | candidate/Map |
      if candidate["id"] == attachment-id: attachment-input = candidate
    if not attachment or attachment["kind"] != "esp32-app-image" or
        not attachment-input:
      throw "MISSING_MEMORY_IMAGE_ATTACHMENT"
    file-name/string := attachment-input["file"]
    image := esp32-image.Image
        (file.read-contents (fs.join metadata-dir file-name))
    bounds := image.drom-address-bounds
    ranges.add {
      "start": format.hex-address bounds[0],
      "end": format.hex-address bounds[1],
      "kind": "flash-mapped-data",
      "source-attachment-id": attachment-id,
    }
    image.drom-segments.do: | segment/esp32-image.Segment |
      region-inputs.add {
        "id": "$attachment-id:drom-$(segment.index)",
        "name": "Firmware DROM $(segment.index)",
        "address": segment.address,
        "kind": "flash-mapped-data",
        "permissions": "r",
        "transport": {
          "source": "esp32-app-image",
          "attachment-id": attachment-id,
        },
        "content": segment.bytes,
      }
  return ranges

scan stream/ByteArray -> ScanResult:
  frames := []
  diagnostics := {
    "input-bytes": stream.size,
    "valid-frames": 0,
    "crc-errors": 0,
    "prefix-candidate-errors": 0,
    "trailing-candidate-errors": 0,
    "framing-errors": 0,
    "sequence-errors": 0,
    "invalid-frames": 0,
    "invalid-regions": 0,
    "invalid-cpu-frames": 0,
    "prefix-noise-bytes": 0,
    "interframe-noise-bytes": 0,
    "trailing-noise-bytes": 0,
  }
  position := 0
  saw-valid := false
  saw-end := false
  while position < stream.size:
    sync := find-sync stream position
    if sync < 0:
      noise := stream.size - position
      add-noise diagnostics noise saw-valid saw-end
      break
    if sync > position:
      add-noise diagnostics (sync - position) saw-valid saw-end
    if stream.size - sync < FRAME-OVERHEAD:
      if not saw-valid:
        increment diagnostics "prefix-candidate-errors"
      else if saw-end:
        increment diagnostics "trailing-candidate-errors"
      else:
        increment diagnostics "framing-errors"
      add-noise diagnostics (stream.size - sync) saw-valid saw-end
      break
    payload-size := LITTLE-ENDIAN.uint32 stream (sync + 20)
    if payload-size > MAX-PAYLOAD-SIZE:
      if not saw-valid:
        increment diagnostics "prefix-candidate-errors"
      else if saw-end:
        increment diagnostics "trailing-candidate-errors"
      else:
        increment diagnostics "framing-errors"
      add-noise diagnostics 1 saw-valid saw-end
      position = sync + 1
      continue
    frame-size := FRAME-OVERHEAD + payload-size
    if stream.size - sync < frame-size:
      if not saw-valid:
        increment diagnostics "prefix-candidate-errors"
      else if saw-end:
        increment diagnostics "trailing-candidate-errors"
      else:
        increment diagnostics "framing-errors"
      add-noise diagnostics (stream.size - sync) saw-valid saw-end
      break
    body-from := sync + 4
    body-to := sync + 24 + payload-size
    expected-crc := LITTLE-ENDIAN.uint32 stream body-to
    if (crc.crc32 stream[body-from..body-to]) != expected-crc:
      if not saw-valid:
        increment diagnostics "prefix-candidate-errors"
      else if saw-end:
        increment diagnostics "trailing-candidate-errors"
      else:
        increment diagnostics "crc-errors"
      add-noise diagnostics 1 saw-valid saw-end
      position = sync + 1
      continue

    frame := Frame
        --type=stream[sync + 4]
        --kind=stream[sync + 5]
        --flags=LITTLE-ENDIAN.uint16 stream (sync + 6)
        --sequence=LITTLE-ENDIAN.uint32 stream (sync + 8)
        --region-id=LITTLE-ENDIAN.uint32 stream (sync + 12)
        --address=LITTLE-ENDIAN.uint32 stream (sync + 16)
        --payload=stream[sync + 24..body-to]
    frames.add frame
    increment diagnostics "valid-frames"
    saw-valid = true
    if frame.type == TYPE-END: saw-end = true
    position = sync + frame-size
  return ScanResult --frames=frames --diagnostics=diagnostics

find-sync bytes/ByteArray from/int -> int:
  position := from
  while position + 4 <= bytes.size:
    position = bytes.index-of 'T' --from=position
    if position < 0: return -1
    if bytes[position..position + 4].to-string == SYNC: return position
    position++
  return -1

add-noise diagnostics/Map count/int saw-valid/bool saw-end/bool -> none:
  if count <= 0: return
  key := not saw-valid
      ? "prefix-noise-bytes"
      : saw-end
          ? "trailing-noise-bytes"
          : "interframe-noise-bytes"
  diagnostics[key] += count

increment map/Map key/string -> none:
  map[key] += 1

add-reason reasons/List reason/string -> none:
  if not reasons.contains reason: reasons.add reason

decode-info payload/ByteArray -> Map:
  return {
    "format-version": LITTLE-ENDIAN.uint32 payload 0,
    "chip-model": LITTLE-ENDIAN.uint32 payload 4,
    "chip-revision": LITTLE-ENDIAN.uint32 payload 8,
    "core-count": LITTLE-ENDIAN.uint32 payload 12,
    "chip-features": LITTLE-ENDIAN.uint32 payload 16,
    "console-uart": LITTLE-ENDIAN.uint32 payload 20,
    "console-baud": LITTLE-ENDIAN.uint32 payload 24,
    "expected-region-count": LITTLE-ENDIAN.uint32 payload 28,
    "physical-psram-size": LITTLE-ENDIAN.uint32 payload 32,
    "mapped-psram-size": LITTLE-ENDIAN.uint32 payload 36,
    "capture-flags": LITTLE-ENDIAN.uint32 payload 40,
  }

decode-end payload/ByteArray -> Map:
  return {
    "region-count": LITTLE-ENDIAN.uint32 payload 0,
    "chunk-count": LITTLE-ENDIAN.uint32 payload 4,
    "byte-count": LITTLE-ENDIAN.uint32 payload 8,
  }

decode-cpu-register-input frame/Frame -> Map:
  payload := frame.payload
  if payload.size < 20 or ((payload.size - 20) % 8) != 0:
    throw "INVALID_CPU_FRAME"
  payload-version := LITTLE-ENDIAN.uint32 payload 0
  core := LITTLE-ENDIAN.uint32 payload 4
  architecture := LITTLE-ENDIAN.uint32 payload 8
  provenance := LITTLE-ENDIAN.uint32 payload 12
  pair-count := LITTLE-ENDIAN.uint32 payload 16
  if payload-version != 1 or pair-count != (payload.size - 20) / 8:
    throw "INVALID_CPU_FRAME"
  if architecture != CPU-ARCHITECTURE-XTENSA and
      architecture != CPU-ARCHITECTURE-RISCV:
    throw "INVALID_CPU_FRAME"
  if frame.kind != architecture or frame.region-id != core or
      (frame.flags & ~CPU-FLAGS) != 0:
    throw "INVALID_CPU_FRAME"
  if provenance != CPU-PROVENANCE-CALLING-SAMPLE and
      provenance != CPU-PROVENANCE-IPC-INTERRUPT:
    throw "INVALID_CPU_FRAME"

  values := {:}
  register-ids := {}
  pc/int? := null
  pair-count.repeat: | index/int |
    offset := 20 + index * 8
    register-id := LITTLE-ENDIAN.uint32 payload offset
    if register-ids.contains register-id: throw "INVALID_CPU_FRAME"
    register-ids.add register-id
    name := cpu-register-name architecture register-id
    if not name: throw "INVALID_CPU_FRAME"
    value := LITTLE-ENDIAN.uint32 payload (offset + 4)
    values[name] = format.hex-address value
    if register-id == REGISTER-PC: pc = value
  if pc == null or pc != frame.address: throw "INVALID_CPU_FRAME"

  architecture-name := architecture == CPU-ARCHITECTURE-XTENSA
      ? "xtensa"
      : "riscv"
  provenance-name := provenance == CPU-PROVENANCE-CALLING-SAMPLE
      ? "calling-sample"
      : "ipc-interrupt"
  return {
    "id": "core-$core",
    "core": core,
    "thread-id": null,
    "architecture": architecture-name,
    "encoding": "named-uint32-map",
    "source": "uart-tdm1",
    "values": values,
    "metadata": {
      "wire-frame-sequence": frame.sequence,
      "wire-frame-flags": frame.flags,
      "volatile": (frame.flags & FLAG-VOLATILE) != 0,
      "partial": (frame.flags & FLAG-PARTIAL) != 0,
      "provenance": provenance-name,
      "provenance-id": provenance,
      "register-pair-count": pair-count,
    },
  }

cpu-register-name architecture/int register-id/int -> string?:
  if register-id == REGISTER-PC: return "PC"
  if register-id == REGISTER-SP: return "SP"
  if register-id == REGISTER-STATUS: return "STATUS"
  if register-id == REGISTER-CAUSE: return "CAUSE"
  if register-id == REGISTER-FAULT-ADDRESS: return "FAULT_ADDRESS"
  if architecture == CPU-ARCHITECTURE-XTENSA:
    if register-id == REGISTER-XTENSA-SAR: return "SAR"
    if REGISTER-XTENSA-A0 <= register-id < REGISTER-XTENSA-A0 + 16:
      return "A$(register-id - REGISTER-XTENSA-A0)"
    return null
  if REGISTER-RISCV-X0 <= register-id < REGISTER-RISCV-X0 + 32:
    return "X$(register-id - REGISTER-RISCV-X0)"
  return null

region-input builder/RegionBuilder -> Map:
  return {
    "id": "region-$(builder.region-id)",
    "name": "$(region-kind-name builder.kind) $(builder.region-id)",
    "address": builder.address,
    "kind": region-kind-name builder.kind,
    "permissions": "r",
    "transport": {
      "region-id": builder.region-id,
      "kind": builder.kind,
      "flags": builder.flags,
      "chunks": builder.chunks,
      "first": true,
      "last": true,
    },
    "content": builder.bytes.bytes,
  }

region-kind-name kind/int -> string:
  if kind == 1: return "internal-ram"
  if kind == 2: return "external-ram"
  if kind == 3: return "rtc-ram"
  if kind == 4: return "word-only-internal-ram"
  return "unknown"
