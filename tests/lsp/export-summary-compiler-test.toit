// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import ...tools.lsp.server.summary
import .utils
import system
import system show platform

import expect show *

main args:
  // We are reaching into the server, so we must not spawn the server as
  // a process.
  run-client-test args --no-spawn-process: test it
  // Since we used '--no-spawn-process' we must exit 0.
  exit 0

check-foo-export summary client foo-path:
  expect-equals 1 summary.exports.size
  expo := summary.exports.first
  expect-equals "foo" expo.name
  expect-equals Export.NODES expo.kind
  refs := expo.refs
  expect-equals 1 refs.size
  ref := refs.first
  expect-equals (client.to-uri foo-path) ref.module-uri

test client/LspClient:
  LEVELS ::= 3
  DRIVE ::= platform == system.PLATFORM-WINDOWS ? "c:" : ""
  DIR ::= "$DRIVE/non_existing_dir_toit_test"
  MODULE-NAME-PREFIX ::= "some_non_existing_path"
  relatives := List LEVELS: ".$MODULE-NAME-PREFIX$it"
  paths := List LEVELS: "$DIR/$MODULE-NAME-PREFIX$(it).toit"

  PATH1-CODE ::= """
    import $relatives[1] show foo
    import $relatives[2]
    export foo
    """
  PATH1-CODE-ALL ::= """
    import $relatives[1] show foo
    import $relatives[2]
    export *
    """

  PATH2-CODE ::= "foo: return \"from path2\""
  PATH3-CODE ::= "foo: return \"from path3\""

  LEVELS.repeat:
    client.send-did-open --path=paths[it] --text=""

  client.send-did-change --path=paths[0] PATH1-CODE
  client.send-did-change --path=paths[1] PATH2-CODE
  client.send-did-change --path=paths[2] PATH3-CODE

  LEVELS.repeat:
    diagnostics := client.diagnostics-for --path=paths[it]
    expect-equals 0 diagnostics.size

  document-uri := client.to-uri paths[0]
  project-uri := client.server.documents_.project-uri-for --uri=(client.to-uri paths[0])
  analyzed-documents := client.server.documents_.analyzed-documents-for --project-uri=project-uri

  document :=  analyzed-documents.get-existing --uri=document-uri
  summary := document.summary

  expect summary.exported-modules.is-empty
  check-foo-export summary client paths[1]

  client.send-did-change --path=paths[0] PATH1-CODE-ALL
  LEVELS.repeat:
    diagnostics := client.diagnostics-for --path=paths[it]
    expect-equals 0 diagnostics.size

  document =  analyzed-documents.get-existing --uri=document-uri
  summary = document.summary

  expect-equals 1 summary.exported-modules.size
  expect-equals (client.to-uri paths[2]) summary.exported-modules.first
  check-foo-export summary client paths[1]
