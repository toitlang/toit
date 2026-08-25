// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.json
import fs
import host.file
import io
import net
import net.modules.tcp

import ..gdb.src.gdb as gdb
import .capture-scope as capture-scope
import .checkpoints as checkpoints
import .description as description
import .format as format
import .qmp as qmp
import .target as target

GDB-TARGET-DESCRIPTION-ID ::= "qemu-gdb-target-description"
HMP-REGISTER-OUTPUT-ID ::= "qemu-hmp-register-output"
CHECKPOINT-LAYOUT-ID ::= "qemu-checkpoint-layout"

main args/List:
  if args.size != 4 and args.size != 6 and args.size != 7:
    print "Usage: qemu-acquire QMP_PORT GDB_PORT MANIFEST.json RESOLVED.json [CHECKPOINT-LAYOUT.json CHECKPOINT [PROCESS-GROUP-ID]]"
    throw "INVALID_ARGUMENTS"
  acquire
      int.parse args[0]
      int.parse args[1]
      args[2]
      args[3]
      --checkpoint-layout-path=(args.size >= 6 ? args[4] : null)
      --checkpoint-name=(args.size >= 6 ? args[5] : null)
      --process-group-id=(args.size == 7 ? int.parse args[6] : null)

acquire qmp-port/int gdb-port/int manifest-path/string resolved-path/string -> none
    --checkpoint-layout-path/string?=null
    --checkpoint-name/string?=null
    --process-group-id/int?=null:
  if (checkpoint-layout-path and not checkpoint-name) or
      (checkpoint-name and not checkpoint-layout-path):
    throw "INCOMPLETE_CHECKPOINT_ARGUMENTS"
  if process-group-id != null and not checkpoint-name:
    throw "SELECTIVE_CAPTURE_REQUIRES_CHECKPOINT"
  if process-group-id != null and checkpoint-name != "mutator-armed" and
      checkpoint-name != "gc-complete":
    throw "SELECTIVE_CAPTURE_REQUIRES_STABLE_CHECKPOINT"
  manifest-dir := fs.dirname manifest-path
  if (fs.dirname resolved-path) != manifest-dir:
    throw "RESOLVED_MANIFEST_DIRECTORY_MISMATCH"
  if not safe-hmp-path manifest-dir: throw "UNSAFE_HMP_PATH"
  manifest/Map := json.decode (file.read-contents manifest-path)
  source-regions/List := manifest["regions"]
  psram-readable := source-regions.any: | region/Map | is-psram-region region
  psram-regions := source-regions.filter: | region/Map | is-psram-region region
  regions := validate-regions manifest manifest-dir

  network := net.open
  qmp-socket := connect network qmp-port
  qmp-client := qmp.Client
      (io.Reader.adapt qmp-socket)
      (io.Writer.adapt qmp-socket)
  try:
    qemu-version := qmp-client.execute "query-version"
    gdb-socket := connect network gdb-port
    documents/Map? := null
    register-sets/List? := null
    checkpoint-evidence/Map? := null
    cpus/List? := null
    try:
      if not checkpoint-name: qmp-client.execute "stop"
      status/Map := qmp-client.execute "query-status"
      initial-status := status.get "status"
      if checkpoint-name:
        // A machine started with -S is normally in QEMU's "prelaunch" state.
        // Some versions report it as "paused" instead, so accept both spellings.
        if initial-status != "prelaunch" and initial-status != "paused":
          throw "QEMU_NOT_WAITING_AT_START"
      else if initial-status != "paused":
        throw "QEMU_NOT_PAUSED"
      gdb-client := gdb.Client
          (io.Reader.adapt gdb-socket)
          (io.Writer.adapt gdb-socket)
      gdb-client.initialize
      if checkpoint-name:
        if (fs.dirname checkpoint-layout-path) != manifest-dir:
          throw "CHECKPOINT_LAYOUT_DIRECTORY_MISMATCH"
        checkpoint-layout := checkpoints.load-layout checkpoint-layout-path
        checkpoint-evidence = checkpoints.run-to-checkpoint
            gdb-client
            checkpoint-layout
            checkpoint-name
        checkpoint-evidence["layout-attachment-id"] = CHECKPOINT-LAYOUT-ID
        status = qmp-client.execute "query-status"
        checkpoint-status := status.get "status"
        // A GDB breakpoint is a stopped VM state named "debug" by QEMU.
        // Retain "paused" for stubs which map debugger stops to that state.
        if checkpoint-status != "debug" and checkpoint-status != "paused":
          throw "QEMU_NOT_PAUSED_AT_CHECKPOINT: $(status.get "status")"
        if process-group-id != null:
          runtime-layout := runtime-layout-from-manifest manifest manifest-dir
          memory-reader := GdbMemoryReader gdb-client regions
          scope-plan := capture-scope.plan-process-group
              memory-reader
              runtime-layout
              process-group-id
          scope/Map := scope-plan["capture-scope"]
          scope["source-region-ids"] = source-regions.map: it["id"]
          scope["source-memory"] = {
            "psram-readable": psram-readable,
            "psram-region-ids": psram-regions.map: it["id"],
          }
          manifest["regions"] = scope-plan["regions"]
          manifest["capture-scope"] = scope
          regions = validate-regions manifest manifest-dir

      cpus = qmp-client.execute "query-cpus-fast"
      capture-regions qmp-client regions
      exception := catch:
        result := capture-gdb-registers gdb-client
        documents = result[0]
        register-sets = result[1]
      if exception and not exception is gdb.UnsupportedQxfer: throw exception
    finally:
      gdb-socket.close

    attachment/Map := ?
    register-source/string := ?
    if documents:
      name := "qemu-gdb-target-description.json"
      file.write-contents
          --path=fs.join manifest-dir name
          (json.encode {"documents": documents})
      attachment = {
        "id": GDB-TARGET-DESCRIPTION-ID,
        "kind": "gdb-target-description",
        "name": name,
        "file": name,
        "metadata": {"source": "qemu-gdb-remote"},
      }
      register-source = "qemu-gdb-remote"
    else:
      hmp-output/string := qmp-client.execute
          "human-monitor-command"
          {"command-line": "info registers -a"}
      register-sets = capture-named-registers hmp-output cpus
      name := "qemu-hmp-register-output.txt"
      file.write-contents --path=(fs.join manifest-dir name) hmp-output
      attachment = {
        "id": HMP-REGISTER-OUTPUT-ID,
        "kind": "qemu-hmp-register-output",
        "name": name,
        "file": name,
        "metadata": {
          "source": "qemu-qmp-human-monitor-command",
          "parser": "validated-named-uint32-v1",
        },
      }
      register-source = "qemu-qmp-hmp-validated"

    attachments/List := manifest.get "attachments" --if-absent=: []
    if checkpoint-evidence:
      checkpoint-file := fs.basename checkpoint-layout-path
      checkpoint-attachment := {
        "id": CHECKPOINT-LAYOUT-ID,
        "kind": "qemu-checkpoint-layout",
        "name": checkpoint-file,
        "file": checkpoint-file,
        "metadata": {"source": "firmware-elf"},
      }
      add-attachment attachments checkpoint-attachment
    add-attachment attachments attachment
    manifest["attachments"] = attachments
    manifest["register-sets"] = register-sets
    provenance/Map := manifest.get "provenance" --init=: {:}
    provenance["acquisition"] = "qemu-qmp-memsave+gdb-remote"
    capture-mode := checkpoint-evidence ? "runtime-checkpoint" : "asynchronous"
    provenance["capture-mode"] = capture-mode
    provenance["semantic-coherence"] = false
    provenance["qemu-version"] = qemu-version
    provenance["qmp-cpus"] = cpus
    provenance["register-source"] = register-source
    provenance["source-memory"] = {
      "region-ids": source-regions.map: it["id"],
      "psram-readable": psram-readable,
    }
    if checkpoint-evidence: provenance["capture-point"] = checkpoint-evidence
    if not manifest.contains "capture-scope":
      manifest["capture-scope"] = {"kind": "full-device"}
    completeness/Map := manifest.get "completeness" --init=: {:}
    completeness["capture-mode"] = capture-mode
    completeness["semantic-coherence"] = false
    missing/List := completeness.get "missing-regions" --if-absent=: []
    completeness["missing-regions"] = missing.filter:
      it != "registers" and (it != "psram" or not psram-readable)
    if process-group-id != null:
      add-if-absent completeness["missing-regions"] "unselected-process-groups"
      scope/Map := manifest["capture-scope"]
      if not scope["unresolved"].is-empty:
        add-if-absent completeness["missing-regions"] "unresolved-owned-memory"
      completeness["note"] = "Selective process-group capture; included ranges and unresolved dependencies are recorded in capture-scope."
    file.write-contents --path=resolved-path ((json.encode manifest) + #[10])
    qmp-client.quit
  finally:
    qmp-socket.close

runtime-layout-from-manifest manifest/Map manifest-dir/string -> Map:
  runtime-layout-input/Map? := manifest.get "runtime-layout"
  if runtime-layout-input:
    runtime-layout-name := runtime-layout-input.get "file"
    if not runtime-layout-name is string or
        not safe-file-name runtime-layout-name:
      throw "INVALID_RUNTIME_LAYOUT_FILE"
    return json.decode
        file.read-contents (fs.join manifest-dir runtime-layout-name)

  attachments/List := manifest.get "attachments" --if-absent=: []
  envelope-input/Map? := null
  attachments.do: | input/Map |
    kind := input.get "kind"
    if kind == "firmware-envelope":
      if envelope-input: throw "MULTIPLE_FIRMWARE_ENVELOPES"
      envelope-input = input
  if not envelope-input: throw "RUNTIME_LAYOUT_REQUIRED"
  envelope-name := envelope-input.get "file"
  if not envelope-name is string or not safe-file-name envelope-name:
    throw "INVALID_FIRMWARE_ENVELOPE_FILE"
  inspector-description := description.from-envelope
      file.read-contents (fs.join manifest-dir envelope-name)
  if not inspector-description: throw "INSPECTOR_DESCRIPTION_NOT_AVAILABLE"
  return inspector-description["runtime-layout"]

add-attachment attachments/List attachment/Map -> none:
  if (attachments.any: | item/Map | (item.get "id") == attachment["id"]):
    throw "DUPLICATE_ATTACHMENT_ID"
  attachments.add attachment

add-if-absent values/List value/any -> none:
  if not values.contains value: values.add value

is-psram-region region/Map -> bool:
  kind := region.get "kind"
  return kind == "external-ram" or kind == "psram"

class GdbMemoryReader implements target.MemoryReader:
  client_/gdb.Client
  allowed_/List

  constructor .client_ .allowed_:

  read address/int length/int -> ByteArray:
    if length <= 0: throw "INVALID_SELECTIVE_READ"
    if allows address length: return client_.read-memory address length
    throw "SELECTIVE_READ_OUTSIDE_MANIFEST"

  allows address/int length/int -> bool:
    if length <= 0: return false
    allowed_.do: | region/Map |
      start := format.parse-address region["address"]
      if address >= start and address + length <= start + region["size"]:
        return true
    return false

connect network/net.Interface port/int -> tcp.TcpSocket:
  200.repeat:
    socket := tcp.TcpSocket network
    exception := catch: socket.connect "127.0.0.1" port
    if not exception: return socket
    socket.close
    sleep --ms=50
  throw "QEMU_CONNECTION_TIMEOUT"

validate-regions manifest/Map manifest-dir/string -> List:
  result := []
  inputs/List := manifest.get "regions" --if-absent=: []
  inputs.do: | region/Map |
    address := region.get "address"
    size := region.get "size"
    name := region.get "file"
    if not address is string or not valid-hex-address address:
      throw "INVALID_REGION_ADDRESS"
    if not size is int or size <= 0: throw "INVALID_REGION_SIZE"
    if not name is string or not safe-file-name name:
      throw "INVALID_REGION_FILE"
    result.add {
      "address": address,
      "size": size,
      "path": fs.join manifest-dir name,
    }
  if result.is-empty: throw "NO_CAPTURE_REGIONS"
  return result

capture-regions client/qmp.Client regions/List -> none:
  regions.do: | region/Map |
    path/string := region["path"]
    address/string := region["address"]
    size/int := region["size"]
    if file.is-file path: file.delete path
    response := client.execute
        "human-monitor-command"
        {
          "command-line": "memsave $address $size \"$path\"",
        }
    if response != null and response != "": throw "QEMU_MEMSAVE_FAILED"
    actual-size := file.size path
    if actual-size != region["size"]: throw "QEMU_MEMSAVE_SIZE_MISMATCH"

capture-gdb-registers client/gdb.Client -> List:
  documents := target-documents client
  architecture := architecture-from-documents documents
  threads := threads-from-xml (client.read-qxfer "threads" "").to-string
  threads.sort --in-place: | a/Map b/Map | a["core"] - b["core"]
  register-sets := []
  threads.do: | thread/Map |
    thread-id/string := thread["thread-id"]
    if (client.request "Hg$thread-id").to-string != "OK":
      throw "GDB_THREAD_SELECTION_FAILED"
    packet := client.request "g"
    if not valid-register-packet packet.to-string:
      throw "INVALID_GDB_REGISTER_PACKET"
    register-sets.add {
      "id": "core-$(thread["core"])",
      "core": thread["core"],
      "thread-id": thread-id,
      "architecture": architecture,
      "byte-order": "little",
      "encoding": "gdb-remote-register-packet",
      "data": lower-hex packet.to-string,
      "layout-attachment-id": GDB-TARGET-DESCRIPTION-ID,
      "source": "qemu-gdb-remote",
      "metadata": {:},
    }
  return [documents, register-sets]

target-documents client/gdb.Client -> Map:
  documents := {:}
  pending := Deque
  pending.add "target.xml"
  while not pending.is-empty:
    annex/string := pending.remove-first
    if documents.contains annex: continue
    xml := (client.read-qxfer "features" annex).to-string
    documents[annex] = xml
    includes := xml-includes xml
    includes.do: | href/string |
      if not documents.contains href and not pending.contains href:
        pending.add href
  return documents

architecture-from-documents documents/Map -> string:
  documents.do: | _ xml/string |
    value := xml-tag-text xml "architecture"
    if value: return value
  throw "GDB_ARCHITECTURE_MISSING"

threads-from-xml xml/string -> List:
  result := []
  offset := 0
  while true:
    start := xml.index-of "<thread " offset
    if start < 0: break
    end := xml.index-of ">" start
    if end < 0: throw "INVALID_GDB_THREADS_XML"
    tag := xml[start..end + 1]
    thread-id := xml-attribute tag "id"
    if not thread-id: throw "GDB_THREAD_ID_MISSING"
    core-text := xml-attribute tag "core"
    core := core-text ? parse-natural core-text : result.size
    result.add {"thread-id": thread-id, "core": core}
    offset = end + 1
  if result.is-empty: throw "GDB_THREADS_MISSING"
  return result

capture-named-registers output/string cpus/List -> List:
  cpu-by-index := {:}
  cpus.do: | cpu/Map | cpu-by-index[cpu["cpu-index"].to-string] = cpu
  values-by-core := {:}
  current/Map? := null
  normalized-output := output.replace --all "\r" ""
  lines := normalized-output.split "\n"
  lines.do: | raw-line/string |
    line := raw-line.trim
    if line.starts-with "CPU#":
      core := int.parse line[4..]
      if not cpu-by-index.contains core.to-string or values-by-core.contains core.to-string:
        throw "UNEXPECTED_HMP_CPU"
      current = {:}
      values-by-core[core.to-string] = current
      continue.do
    if not current: continue.do
    (line.split " ").do: | token/string |
      equal := token.index-of "="
      if equal <= 0: continue.do
      name := token[..equal]
      value := token[equal + 1..]
      if not valid-register-name name or value.size != 8 or not valid-hex value:
        continue.do
      if current.contains name: throw "DUPLICATE_HMP_REGISTER"
      current[name] = "0x$(lower-hex value)"

  result := []
  cpus.do: | cpu/Map |
    core/int := cpu["cpu-index"]
    values/Map? := values-by-core.get core.to-string
    if not values: throw "MISSING_HMP_CPU"
    required := ["PC", "PS"]
    16.repeat: required.add "A$(two-digits it)"
    required.do:
      if not values.contains it: throw "MISSING_HMP_REGISTER: core=$core name=$it"
    result.add {
      "id": "core-$core",
      "core": core,
      "thread-id": "$(cpu["thread-id"])",
      "architecture": cpu["target"],
      "byte-order": "little",
      "encoding": "named-uint32-map",
      "values": values,
      "source-attachment-id": HMP-REGISTER-OUTPUT-ID,
      "source": "qemu-qmp-hmp-validated",
      "metadata": {"qom-path": cpu.get "qom-path"},
    }
  result.sort --in-place: | a/Map b/Map | a["core"] - b["core"]
  return result

xml-includes xml/string -> List:
  result := []
  offset := 0
  while true:
    start := xml.index-of "href=\"" offset
    if start < 0: break
    from := start + 6
    end := xml.index-of "\"" from
    if end < 0: throw "INVALID_XML_ATTRIBUTE"
    result.add xml[from..end]
    offset = end + 1
  return result

xml-tag-text xml/string name/string -> string?:
  open := "<$name>"
  close := "</$name>"
  start := xml.index-of open
  if start < 0: return null
  start += open.size
  end := xml.index-of close start
  if end < 0: throw "INVALID_XML_ELEMENT"
  return xml[start..end].trim

xml-attribute tag/string name/string -> string?:
  marker := "$name=\""
  start := tag.index-of marker
  if start < 0: return null
  start += marker.size
  end := tag.index-of "\"" start
  if end < 0: throw "INVALID_XML_ATTRIBUTE"
  return tag[start..end]

valid-register-packet value/string -> bool:
  if value.is-empty or (value.size & 1) != 0: return false
  value.do: | rune/int |
    if not is-hex rune and rune != 'x' and rune != 'X': return false
  return true

valid-register-name value/string -> bool:
  if value.is-empty: return false
  value.do: | rune/int |
    if not ('A' <= rune <= 'Z' or '0' <= rune <= '9' or rune == '_'):
      return false
  return 'A' <= value[0] <= 'Z'

valid-hex-address value/string -> bool:
  return value.starts-with "0x" and value.size > 2 and valid-hex value[2..]

valid-hex value/string -> bool:
  if value.is-empty: return false
  value.do: | rune/int | if not is-hex rune: return false
  return true

is-hex rune/int -> bool:
  return '0' <= rune <= '9' or 'a' <= rune <= 'f' or 'A' <= rune <= 'F'

lower-hex value/string -> string:
  return value.flat-map: | rune/int |
    'A' <= rune <= 'F' ? rune - 'A' + 'a' : rune

parse-natural value/string -> int:
  return value.starts-with "0x"
      ? int.parse --radix=16 value[2..]
      : int.parse value

two-digits value/int -> string:
  return value < 10 ? "0$value" : "$value"

safe-file-name value/string -> bool:
  if value.is-empty: return false
  value.do: | rune/int |
    if not ('a' <= rune <= 'z' or 'A' <= rune <= 'Z' or
        '0' <= rune <= '9' or rune == '_' or rune == '-' or rune == '.'):
      return false
  return true

safe-hmp-path value/string -> bool:
  if value.is-empty: return false
  value.do: | rune/int |
    if not ('a' <= rune <= 'z' or 'A' <= rune <= 'Z' or
        '0' <= rune <= '9' or rune == '_' or rune == '-' or rune == '.' or
        rune == '/'):
      return false
  return true
