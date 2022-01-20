// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp_client show LspClient run_client_test
import ...tools.lsp.server.summary
import .utils

import expect show *

main args:
  // We are reaching into the server, so we must not spawn the server as
  // a process.
  run_client_test args --no-spawn_process: test it
  // Since we used '--no-spawn_process' we must exit 0.
  exit 0

check_foo_export summary client foo_path:
  expect_equals 1 summary.exports.size
  expo := summary.exports.first
  expect_equals "foo" expo.name
  expect_equals Export.NODES expo.kind
  refs := expo.refs
  expect_equals 1 refs.size
  ref := refs.first
  expect_equals (client.to_uri foo_path) ref.module_uri

test client/LspClient:
  LEVELS ::= 3
  DIR ::= "/non_existing_dir_toit_test"
  MODULE_NAME_PREFIX ::= "some_non_existing_path"
  relatives := List LEVELS: ".$MODULE_NAME_PREFIX$it"
  paths := List LEVELS: "$DIR/$MODULE_NAME_PREFIX$(it).toit"

  PATH1_CODE ::= """
    import $relatives[1] show foo
    import $relatives[2]
    export foo
    """
  PATH1_CODE_ALL ::= """
    import $relatives[1] show foo
    import $relatives[2]
    export *
    """

  PATH2_CODE ::= "foo: return \"from path2\""
  PATH3_CODE ::= "foo: return \"from path3\""

  LEVELS.repeat:
    client.send_did_open --path=paths[it] --text=""

  client.send_did_change --path=paths[0] PATH1_CODE
  client.send_did_change --path=paths[1] PATH2_CODE
  client.send_did_change --path=paths[2] PATH3_CODE

  LEVELS.repeat:
    diagnostics := client.diagnostics_for --path=paths[it]
    expect_equals 0 diagnostics.size

  document := client.server.documents_.get_existing_document --path=paths[0]
  summary := document.summary

  expect summary.exported_modules.is_empty
  check_foo_export summary client paths[1]

  client.send_did_change --path=paths[0] PATH1_CODE_ALL
  LEVELS.repeat:
    diagnostics := client.diagnostics_for --path=paths[it]
    expect_equals 0 diagnostics.size

  document = client.server.documents_.get_existing_document --path=paths[0]
  summary = document.summary

  expect_equals 1 summary.exported_modules.size
  expect_equals (client.to_uri paths[2]) summary.exported_modules.first
  check_foo_export summary client paths[1]
