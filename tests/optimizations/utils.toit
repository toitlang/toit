// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ...tools.snapshot
import ...tools.lsp.server.client show with_lsp_client LspClient
import host.directory
import host.file
import host.pipe
import host.tar show Tar
import encoding.base64 as base64

run args/List --entry_path/string sources/Map={:} -> SnapshotBundle:
  toitc      /string := args[0]
  lsp_server /string := args[1]
  with_lsp_client
      --toitc=toitc
      --lsp_server=lsp_server
      --compiler_exe=toitc
      --spawn_process  // Maybe a tiny bit slower, but easier to handle.
      --supports_config=false: |client/LspClient|
    sources.do: |path content|
      client.send_did_open --path=path --text=content
    snapshot_bundle := client.send_request "toit/snapshot_bundle" { "uri": client.to_uri entry_path }
    if not snapshot_bundle or not snapshot_bundle["snapshot_bundle"]: throw "Unsuccessful compilation"
    result := SnapshotBundle (base64.decode snapshot_bundle["snapshot_bundle"])
    return result
  unreachable

extract_methods program/Program method_names/List -> Map:
  result := {:}
  method_names.do: result[it] = null
  methods := program.methods
  methods.do:
    debug_info := program.method_info_for it.id
    name := debug_info.prefix_string program
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

target_of_invoke_static program/Program method/ToitMethod bci/int -> MethodInfo:
  assert: BYTE_CODES[method.bytecodes[bci]].name == "INVOKE_STATIC"
  dispatch_index := method.uint16 bci + 1
  target := program.dispatch_table[dispatch_index]
  return program.method_info_for target
