// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import crypto.sha256 as crypto
import encoding.json
import fs
import host.file

import ..snapshot as snapshot

main args/List:
  if args.size != 2:
    print "Usage: extract-program-layout SNAPSHOT OUTPUT.json"
    throw "INVALID_ARGUMENTS"
  extract-program-layout args[0] args[1]

extract-program-layout snapshot-path/string output/string -> none:
  snapshot-bytes := file.read-contents snapshot-path
  bundle := snapshot.SnapshotBundle snapshot-bytes
  if not bundle.has-source-map: throw "SNAPSHOT_SOURCE_MAP_REQUIRED"
  program := bundle.decode
  methods := []
  program.methods.do: | method/snapshot.ToitMethod |
    info := program.method-info-for method.id
    frame-debug := program.frame-debug-info-for method.id: null
    positions := []
    last-line := -1
    last-column := -1
    (method.bytecodes.size + 1).repeat: | relative-bci |
      position := info.position relative-bci
      if position.line == last-line and position.column == last-column:
        continue.repeat
      positions.add {
        "relative-bci": relative-bci,
        "line": position.line,
        "column": position.column,
      }
      last-line = position.line
      last-column = position.column
    method-entry := {
      "header-bci": method.id,
      "entry-bci": method.absolute-entry-bci,
      "end-bci": method.id + method.allocation-size,
      "bytecode-size": method.bytecodes.size,
      "name": info.prefix-string program,
      "kind": method-kind method,
      "arity": method.arity,
      "max-height": method.max-height,
      "path": info.error-path,
      "positions": positions,
    }
    if frame-debug:
      method-entry["parameters"] = frame-debug.parameters.map:
          | parameter/snapshot.ParameterDebugInfo |
        result := {
          "index": parameter.index,
          "name": parameter.name,
          "kind": parameter.kind,
        }
        if parameter.position:
          result["line"] = parameter.position.line
          result["column"] = parameter.position.column
        result
      method-entry["locals"] = frame-debug.locals.map:
          | local/snapshot.LocalDebugInfo |
        {
          "stack-height": local.stack-height,
          "start-bci": local.start-bci,
          "end-bci": local.end-bci,
          "name": local.name,
          "line": local.position.line,
          "column": local.position.column,
        }
    methods.add method-entry
  classes := []
  program.do --class-infos: | info/snapshot.ClassInfo |
    class-entry := {
      "id": info.id,
      "name": info.name,
      "super-id": info.super-id,
      "path": info.error-path,
      "line": info.position.line,
      "column": info.position.column,
      "fields": info.fields,
      "all-fields": flattened-fields program info,
    }
    if info.id < program.class-tags.size:
      class-entry["type-tag"] = program.class-tags[info.id]
      class-entry["instance-size"] = program.class-instance-sizes[info.id] * 4
    classes.add class-entry
  globals := program.global-table.map: | info/snapshot.GlobalInfo |
    {
      "id": info.id,
      "name": info.name,
      "holder-id": info.holder-id,
      "holder-name": info.holder-name,
    }
  layout := {
    "format": "toit-program-layout",
    "format-version": 2,
    "source": fs.basename snapshot-path,
    "source-snapshot-sha256": hex-digest (crypto.sha256 snapshot-bytes),
    "snapshot-uuid": "$bundle.uuid",
    "sdk-version": bundle.sdk-version,
    "bytecodes-length": program.all-bytecodes.size,
    "bytecodes-sha256": hex-digest (crypto.sha256 program.all-bytecodes),
    "dispatch-table": program.dispatch-table,
    "opcodes": snapshot.BYTE-CODES.map: | bytecode/snapshot.Bytecode |
      {
        "name": bytecode.name,
        "size": bytecode.size,
        "format": bytecode.format,
        "description": bytecode.description,
      },
    "classes": classes,
    "globals": globals,
    "methods": methods,
  }
  file.write-contents --path=output ((json.encode layout) + #[10])

flattened-fields program/snapshot.Program info/snapshot.ClassInfo -> List:
  result := []
  if info.super-id != null:
    super-info := program.class-info-for info.super-id
    result.add-all (flattened-fields program super-info)
  result.add-all info.fields
  return result

method-kind method/snapshot.ToitMethod -> string:
  if method.is-normal-method: return "method"
  if method.is-field-accessor: return "field-accessor"
  if method.is-lambda: return "lambda"
  if method.is-block: return "block"
  return "unknown"

hex-digest bytes/ByteArray -> string:
  result := ""
  bytes.do: | byte/int |
    if byte < 16: result += "0"
    result += byte.to-string --radix=16
  return result
