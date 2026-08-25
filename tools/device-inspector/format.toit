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

import crypto.sha256 as crypto
import encoding.hex
import encoding.json
import fs
import host.file
import io show LITTLE-ENDIAN

import .description as description
import .target as target

MAGIC ::= "TOITDUMP"
FORMAT-VERSION ::= 1
PREFIX-SIZE ::= 16

class Region implements target.MemoryRegion:
  id/string
  name/string
  address/int
  size/int
  kind/string
  permissions/string
  payload-offset/int
  sha256/string
  transport/Map

  constructor --.id --.name --.address --.size --.kind --.permissions
      --.payload-offset --.sha256 --.transport:

  end-address -> int:
    return address + size

  metadata -> Map:
    return {
      "id": id,
      "name": name,
      "address": hex-address address,
      "size": size,
      "end-address": hex-address end-address,
      "kind": kind,
      "permissions": permissions,
      "sha256": sha256,
      "transport": transport,
    }

class Capture implements target.ObservedTarget:
  metadata/Map
  regions/List
  bytes/ByteArray
  payload-start/int

  constructor --.metadata --.regions --.bytes --.payload-start:

  id -> string:
    return metadata["id"]

  read address/int length/int -> ByteArray:
    regions.do: | region/Region |
      if address < region.address: continue.do
      if address + length > region.end-address: continue.do
      offset := payload-start + region.payload-offset + address - region.address
      return bytes[offset..offset + length]
    throw "ADDRESS_NOT_CAPTURED"

  allows address/int length/int -> bool:
    if length <= 0: return false
    regions.do: | region/Region |
      if address >= region.address and address + length <= region.end-address:
        return true
    return false

  observation -> Map:
    completeness/Map := metadata.get "completeness" --if-absent=: {:}
    provenance/Map := metadata.get "provenance" --if-absent=: {:}
    result := {
      "capture-mode": completeness.get "capture-mode" --if-absent=:
          provenance.get "capture-mode" --if-absent=: "unknown",
      "semantic-coherence": completeness.get
          "semantic-coherence"
          --if-absent=:
              provenance.get "semantic-coherence" --if-absent=: false,
    }
    capture-point := provenance.get "capture-point"
    if capture-point: result["runtime-checkpoint"] = capture-point
    return result

hex-address value/int -> string:
  return "0x$(value.to-string --radix=16)"

parse-address value/any -> int:
  if value is int:
    if value < 0: throw "INVALID_ADDRESS"
    return value
  if not value is string: throw "INVALID_ADDRESS"
  if not value.starts-with "0x": throw "INVALID_ADDRESS"
  if value.size <= 2: throw "INVALID_ADDRESS"
  result/int? := null
  catch: result = int.parse value[2..] --radix=16
  if result == null or result < 0: throw "INVALID_ADDRESS"
  return result

bytes-to-hex bytes/ByteArray -> string:
  result := ""
  bytes.do: | byte/int |
    if byte < 16: result += "0"
    result += byte.to-string --radix=16
  return result

load path/string -> Capture:
  bytes := file.read-contents path
  if bytes.size < PREFIX-SIZE: throw "TRUNCATED_DUMP"
  if bytes[..8].to-string != MAGIC: throw "INVALID_DUMP_MAGIC"
  version := LITTLE-ENDIAN.uint32 bytes 8
  if version != FORMAT-VERSION: throw "UNSUPPORTED_DUMP_VERSION"
  header-size := LITTLE-ENDIAN.uint32 bytes 12
  payload-start := PREFIX-SIZE + header-size
  if header-size <= 0 or payload-start > bytes.size: throw "TRUNCATED_DUMP_HEADER"

  metadata/Map := json.decode bytes[PREFIX-SIZE..payload-start]
  if metadata["format"] != "toitdump": throw "INVALID_DUMP_HEADER"
  if metadata["format-version"] != FORMAT-VERSION: throw "INVALID_DUMP_HEADER"
  region-metadata/List := metadata["regions"]
  regions := []
  expected-payload-offset := 0
  region-metadata.do: | entry/Map |
    region := Region
        --id=entry["id"]
        --name=entry["name"]
        --address=parse-address entry["address"]
        --size=entry["size"]
        --kind=entry["kind"]
        --permissions=entry["permissions"]
        --payload-offset=entry["payload-offset"]
        --sha256=entry["sha256"]
        --transport=entry.get "transport" --if-absent=: {:}
    if region.size <= 0 or region.payload-offset != expected-payload-offset:
      throw "INVALID_DUMP_REGION"
    if payload-start + region.payload-offset + region.size > bytes.size:
      throw "TRUNCATED_DUMP_REGION"
    actual-sha := bytes-to-hex
        crypto.sha256 bytes
            payload-start + region.payload-offset
            payload-start + region.payload-offset + region.size
    if actual-sha != region.sha256: throw "DUMP_CHECKSUM_MISMATCH"
    regions.add region
    expected-payload-offset += region.size
  if payload-start + expected-payload-offset != bytes.size: throw "INVALID_DUMP_PAYLOAD"
  validate-non-overlapping regions
  unsigned := {
    "format": metadata["format"],
    "format-version": metadata["format-version"],
    "target": metadata["target"],
    "completeness": metadata["completeness"],
    "provenance": metadata["provenance"],
    "regions": metadata["regions"],
  }
  if metadata.contains "attachments":
    unsigned["attachments"] = metadata["attachments"]
  if metadata.contains "register-sets":
    unsigned["register-sets"] = metadata["register-sets"]
  if metadata.contains "inspector-description":
    unsigned["inspector-description"] = metadata["inspector-description"]
  if metadata.contains "runtime-layout":
    unsigned["runtime-layout"] = metadata["runtime-layout"]
  if metadata.contains "program-layouts":
    unsigned["program-layouts"] = metadata["program-layouts"]
  if metadata.contains "capture-scope":
    unsigned["capture-scope"] = metadata["capture-scope"]
  expected-id := bytes-to-hex
      crypto.sha256 ((json.encode unsigned) + bytes[payload-start..])
  if metadata["id"] != expected-id: throw "DUMP_ID_MISMATCH"
  return Capture --metadata=metadata --regions=regions --bytes=bytes --payload-start=payload-start

import-manifest manifest-path/string output-path/string -> Capture:
  manifest/Map := json.decode (file.read-contents manifest-path)
  manifest-dir := fs.dirname manifest-path
  input-regions/List := manifest["regions"]
  if not input-regions or input-regions.is-empty: throw "NO_CAPTURE_REGIONS"

  region-inputs := []
  input-regions.do: | input/Map |
    file-name/string := input["file"]
    region-path := fs.join manifest-dir file-name
    content := file.read-contents region-path
    requested-size := input.get "size"
    if requested-size and requested-size != content.size: throw "REGION_SIZE_MISMATCH"
    address := parse-address input["address"]
    id/string := input["id"]
    name/string := input.get "name" --if-absent=: id
    kind/string := input.get "kind" --if-absent=: "ram"
    permissions/string := input.get "permissions" --if-absent=: "rw"
    region-inputs.add {
      "id": id,
      "name": name,
      "address": address,
      "kind": kind,
      "permissions": permissions,
      "transport": input.get "transport" --if-absent=: {:},
      "content": content,
    }
  completeness/Map := manifest.get "completeness" --if-absent=: {
    "state": "partial",
    "reason": "The importer was not told that every relevant region was captured.",
  }
  if completeness["state"] != "complete" and completeness["state"] != "partial":
    throw "INVALID_COMPLETENESS"
  target/Map := manifest.get "target" --if-absent=: {:}
  provenance/Map := manifest.get "provenance" --if-absent=: {:}
  attachments := import-attachments
      manifest-dir
      manifest.get "attachments" --if-absent=: []
  register-sets := normalize-register-sets
      manifest.get "register-sets" --if-absent=: []
      attachments
  inspector-description := import-envelope-description
      manifest-dir
      manifest.get "attachments" --if-absent=: []
      attachments
  legacy-runtime-layout := import-runtime-layout
      manifest-dir
      manifest.get "runtime-layout"
      attachments
  runtime-layout/Map? := inspector-description
      ? inspector-description["runtime-layout"]
      : legacy-runtime-layout
  if inspector-description and legacy-runtime-layout and
      not runtime-layouts-equivalent
          inspector-description["runtime-layout"]
          legacy-runtime-layout:
    throw "INSPECTOR_DESCRIPTION_RUNTIME_LAYOUT_MISMATCH"
  program-layouts := import-program-layouts
      manifest-dir
      manifest.get "program-layouts" --if-absent=: []
      attachments
  capture-scope := normalize-capture-scope (manifest.get "capture-scope")
  return write-capture
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

write-capture
    output-path/string
    target/Map
    completeness/Map
    provenance/Map
    region-inputs/List
    --attachments/List=[]
    --register-sets/List=[]
    --inspector-description/Map?=null
    --runtime-layout/Map?=null
    --program-layouts/List=[]
    --capture-scope/Map?=null
    -> Capture:
  if region-inputs.is-empty: throw "NO_CAPTURE_REGIONS"
  regions := []
  payload := ByteArray 0
  region-entries := []
  region-inputs.do: | input/Map |
    content/ByteArray := input["content"]
    if content.is-empty: throw "EMPTY_CAPTURE_REGION"
    id/string := input["id"]
    name/string := input["name"]
    address/int := input["address"]
    kind/string := input["kind"]
    permissions/string := input["permissions"]
    transport/Map := input.get "transport" --if-absent=: {:}
    digest := bytes-to-hex (crypto.sha256 content)
    region := Region
        --id=id
        --name=name
        --address=address
        --size=content.size
        --kind=kind
        --permissions=permissions
        --payload-offset=payload.size
        --sha256=digest
        --transport=transport
    regions.add region
    region-entries.add {
      "id": id,
      "name": name,
      "address": hex-address address,
      "size": content.size,
      "kind": kind,
      "permissions": permissions,
      "payload-offset": payload.size,
      "sha256": digest,
      "transport": transport,
    }
    payload += content

  validate-non-overlapping regions
  unsigned := {
    "format": "toitdump",
    "format-version": FORMAT-VERSION,
    "target": target,
    "completeness": completeness,
    "provenance": provenance,
    "regions": region-entries,
  }
  if not attachments.is-empty: unsigned["attachments"] = attachments
  if not register-sets.is-empty: unsigned["register-sets"] = register-sets
  if inspector-description:
    unsigned["inspector-description"] = inspector-description
  if runtime-layout: unsigned["runtime-layout"] = runtime-layout
  if not program-layouts.is-empty: unsigned["program-layouts"] = program-layouts
  if capture-scope: unsigned["capture-scope"] = capture-scope
  id := bytes-to-hex (crypto.sha256 ((json.encode unsigned) + payload))
  metadata := {
    "format": "toitdump",
    "format-version": FORMAT-VERSION,
    "id": id,
    "target": target,
    "completeness": completeness,
    "provenance": provenance,
    "regions": region-entries,
  }
  if not attachments.is-empty: metadata["attachments"] = attachments
  if not register-sets.is-empty: metadata["register-sets"] = register-sets
  if inspector-description:
    metadata["inspector-description"] = inspector-description
  if runtime-layout: metadata["runtime-layout"] = runtime-layout
  if not program-layouts.is-empty: metadata["program-layouts"] = program-layouts
  if capture-scope: metadata["capture-scope"] = capture-scope
  header := json.encode metadata
  prefix := MAGIC.to-byte-array + (ByteArray 8)
  LITTLE-ENDIAN.put-uint32 prefix 8 FORMAT-VERSION
  LITTLE-ENDIAN.put-uint32 prefix 12 header.size
  file.write-contents --path=output-path (prefix + header + payload)
  return load output-path

normalize-capture-scope input/any -> Map?:
  if input == null: return null
  if not input is Map: throw "INVALID_CAPTURE_SCOPE"
  kind := input.get "kind"
  if kind != "full-device" and kind != "process-group":
    throw "INVALID_CAPTURE_SCOPE"
  if kind == "process-group":
    selected := input.get "selected"
    if not selected is Map: throw "INVALID_CAPTURE_SCOPE"
    selected-id := selected.get "id"
    if not selected-id is int: throw "INVALID_CAPTURE_SCOPE"
  return input

import-runtime-layout manifest-dir/string input/any attachments/List -> Map?:
  if input == null: return null
  if not input is Map: throw "INVALID_RUNTIME_LAYOUT"
  file-name/string := input["file"]
  layout/Map := json.decode (file.read-contents (fs.join manifest-dir file-name))
  if (layout.get "format") != "toit-runtime-layout" or
      (layout.get "format-version") != 1:
    throw "INVALID_RUNTIME_LAYOUT"
  elf-id/string := input["elf-attachment-id"]
  elf/Map? := null
  attachments.do: | attachment/Map |
    if attachment["id"] == elf-id: elf = attachment
  if not elf or elf["kind"] != "firmware-elf":
    throw "MISSING_RUNTIME_LAYOUT_ELF"
  layout["source-elf-attachment-id"] = elf-id
  layout["source-elf-sha256"] = elf["sha256"]
  return layout

import-envelope-description
    manifest-dir/string inputs/List attachments/List
    -> Map?:
  envelope-inputs := inputs.filter:
    (it.get "kind") == "firmware-envelope"
  if envelope-inputs.is-empty: return null
  if envelope-inputs.size > 1: throw "MULTIPLE_FIRMWARE_ENVELOPES"
  input/Map := envelope-inputs.first
  file-name/string := input["file"]
  content := file.read-contents (fs.join manifest-dir file-name)
  result := description.from-envelope content
  if not result: return null
  attachment-id/string := input["id"]
  attachment/Map? := null
  attachments.do: | candidate/Map |
    if candidate["id"] == attachment-id: attachment = candidate
  if not attachment: throw "MISSING_FIRMWARE_ENVELOPE_ATTACHMENT"
  result["source-envelope-attachment-id"] = attachment-id
  result["source-envelope-sha256"] = attachment["sha256"]
  runtime-layout/Map := result["runtime-layout"]
  runtime-layout["source-envelope-attachment-id"] = attachment-id
  runtime-layout["source-envelope-sha256"] = attachment["sha256"]
  return result

runtime-layouts-equivalent first/Map second/Map -> bool:
  keys := [
    "format",
    "format-version",
    "pointer-size",
    "byte-order",
    "types",
    "symbols",
    "constants",
    "vtables",
  ]
  keys.do: | key/string |
    first-value := json.encode (first.get key)
    second-value := json.encode (second.get key)
    if first-value != second-value: return false
  return true

import-program-layouts manifest-dir/string inputs/List attachments/List -> List:
  result := []
  snapshot-attachments := {:}
  attachments.do: | attachment/Map |
    if attachment["kind"] == "toit-snapshot":
      snapshot-attachments[attachment["id"]] = attachment
  inputs.do: | input/Map |
    file-name/string := input["file"]
    layout/Map := json.decode (file.read-contents (fs.join manifest-dir file-name))
    layout-version := layout.get "format-version"
    if (layout.get "format") != "toit-program-layout" or
        (layout-version != 1 and layout-version != 2) or
        not (layout.get "methods") is List or
        not (layout.get "opcodes") is List:
      throw "INVALID_PROGRAM_LAYOUT"
    snapshot-id/string := input["snapshot-attachment-id"]
    attachment/Map? := snapshot-attachments.get snapshot-id
    if not attachment: throw "MISSING_PROGRAM_LAYOUT_SNAPSHOT"
    if (layout.get "source-snapshot-sha256") != attachment["sha256"]:
      throw "PROGRAM_LAYOUT_SNAPSHOT_MISMATCH"
    bytecodes-length := layout.get "bytecodes-length"
    bytecodes-sha := layout.get "bytecodes-sha256"
    if not bytecodes-length is int or bytecodes-length <= 0 or
        not bytecodes-sha is string or bytecodes-sha.size != 64:
      throw "INVALID_PROGRAM_LAYOUT"
    layout["source-snapshot-attachment-id"] = snapshot-id
    layout["source-snapshot-name"] = attachment["name"]
    attachment-metadata/Map? := attachment.get "metadata"
    if attachment-metadata:
      container-name := attachment-metadata.get "container"
      if container-name is string:
        layout["source-container-name"] = container-name
    result.add layout
  return result

import-attachments manifest-dir/string inputs/List -> List:
  result := []
  ids := {}
  inputs.do: | input/Map |
    id/string := input["id"]
    if id.is-empty or ids.contains id: throw "INVALID_ATTACHMENT_ID"
    ids.add id
    file-name/string := input["file"]
    content := file.read-contents (fs.join manifest-dir file-name)
    expected-size := input.get "size"
    if expected-size and expected-size != content.size:
      throw "ATTACHMENT_SIZE_MISMATCH"
    digest := bytes-to-hex (crypto.sha256 content)
    expected-digest := input.get "sha256"
    if expected-digest and expected-digest != digest:
      throw "ATTACHMENT_CHECKSUM_MISMATCH"
    result.add {
      "id": id,
      "kind": input["kind"],
      "name": input.get "name" --if-absent=: file-name,
      "file": file-name,
      "size": content.size,
      "sha256": digest,
      "metadata": input.get "metadata" --if-absent=: {:},
    }
  return result

normalize-register-sets inputs/List attachments/List -> List:
  result := []
  ids := {}
  attachment-ids := {}
  attachments.do: attachment-ids.add it["id"]
  inputs.do: | input/Map |
    core/int := input["core"]
    if core < 0: throw "INVALID_REGISTER_SET"
    id/string := input.get "id" --if-absent=: "core-$core"
    if id.is-empty or ids.contains id: throw "INVALID_REGISTER_SET"
    ids.add id
    encoding/string := input["encoding"]
    entry := {
      "id": id,
      "core": core,
      "thread-id": input["thread-id"],
      "architecture": input["architecture"],
      "byte-order": input.get "byte-order" --if-absent=: "little",
      "encoding": encoding,
      "source": input.get "source" --if-absent=: "gdb-remote",
      "metadata": input.get "metadata" --if-absent=: {:},
    }
    if encoding == "gdb-remote-register-packet":
      data/string := input["data"]
      if (data.size & 1) != 0: throw "INVALID_REGISTER_ENCODING"
      validation-data := data.replace --all "x" "0"
      validation-data = validation-data.replace --all "X" "0"
      exception := catch: hex.decode validation-data
      if exception: throw "INVALID_REGISTER_ENCODING"
      layout-id/string := input["layout-attachment-id"]
      if not attachment-ids.contains layout-id:
        throw "MISSING_REGISTER_LAYOUT_ATTACHMENT"
      entry["data"] = normalize-register-data data
      entry["layout-attachment-id"] = layout-id
    else if encoding == "named-uint32-map":
      values/Map := input["values"]
      if values.is-empty: throw "INVALID_REGISTER_ENCODING"
      normalized-values := {:}
      values.do: | name/string value/string |
        parsed := parse-address value
        if parsed > 0xffff_ffff: throw "INVALID_REGISTER_ENCODING"
        normalized-values[name] = uint32-hex parsed
      entry["values"] = normalized-values
      source-id := input.get "source-attachment-id"
      if source-id:
        if not source-id is string or not attachment-ids.contains source-id:
          throw "MISSING_REGISTER_SOURCE_ATTACHMENT"
        entry["source-attachment-id"] = source-id
    else:
      throw "INVALID_REGISTER_ENCODING"
    result.add entry
  return result

normalize-register-data data/string -> string:
  return data.flat-map: | rune/int |
    if 'A' <= rune <= 'F': rune - 'A' + 'a'
    else: rune

uint32-hex value/int -> string:
  digits := value.to-string --radix=16
  return "0x$("00000000"[..8 - digits.size])$digits"

validate-non-overlapping regions/List -> none:
  ids := {}
  regions.do: | first/Region |
    if ids.contains first.id: throw "DUPLICATE_REGION_ID"
    ids.add first.id
    regions.do: | second/Region |
      if first == second: continue.do
      if first.address < second.end-address and second.address < first.end-address:
        throw "OVERLAPPING_CAPTURE_REGIONS"
