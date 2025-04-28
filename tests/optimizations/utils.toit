// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ...tools.snapshot
import ...tools.lsp.server.client show with-lsp-client LspClient
import host.directory
import host.file
import host.pipe
import tar show Tar
import encoding.base64 as base64

run args/List --entry-path/string sources/Map={:} -> SnapshotBundle:
  toitc      /string := args[0]
  lsp-server /string := args[1]
  with-lsp-client
      --toitc=toitc
      --lsp-server=lsp-server
      --compiler-exe=toitc
      --spawn-process  // Maybe a tiny bit slower, but easier to handle.
      --supports-config=false: |client/LspClient|
    sources.do: |path content|
      client.send-did-open --path=path --text=content
    snapshot-bundle := client.send-request "toit/snapshotBundle" { "uri": client.to-uri entry-path }
    if not snapshot-bundle or not snapshot-bundle["snapshot_bundle"]: throw "Unsuccessful compilation"
    result := SnapshotBundle (base64.decode snapshot-bundle["snapshot_bundle"])
    return result
  unreachable

extract-methods program/Program method-names/List -> Map:
  result := {:}
  method-names.do: result[it] = null
  methods := program.methods
  methods.do:
    debug-info := program.method-info-for it.id
    name := debug-info.prefix-string program
    if result.contains name:
      result.update name: |old|
        if not old:
          // No value yet.
          it
        else if old is List:
          // Already at least two entries.
          old.add it
          old
        else:
          // Switch from single value to list.
          [old, it]

  return result

target-of-invoke-static program/Program method/ToitMethod bci/int -> MethodInfo:
  assert: BYTE-CODES[method.bytecodes[bci]].name == "INVOKE_STATIC"
  dispatch-index := method.uint16 bci + 1
  target := program.dispatch-table[dispatch-index]
  return program.method-info-for target
