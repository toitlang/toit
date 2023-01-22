// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp_client show LspClient run_client_test
import ...tools.lsp.server.summary
import ...tools.lsp.server.toitdoc_node
import .utils

import host.directory
import expect show *

main args:
  // We are reaching into the server, so we must not spawn the server as
  // a process.
  run_client_test args --no-spawn_process: test it
  // Since we used '--no-spawn_process' we must exit 0.
  exit 0

DRIVE ::= platform == PLATFORM_WINDOWS ? "C:" : ""
FILE_PATH ::= "$DRIVE/tmp/file.toit"

test client/LspClient:
  client.send_did_open --path=FILE_PATH --text=""

  client.send_did_open --path=FILE_PATH --text="""
    class NotImportant:  // ID: 0
    class A:
    interface I1:
    class B extends A implements I1:
    """
  document := client.server.documents_.get_existing_document --path=FILE_PATH
  summary := document.summary
  classes := summary.classes

  expect_equals 4 classes.size
  not_important /Class := classes[0]
  a /Class := classes[1]
  i1 /Class := classes[2]
  b /Class := classes[3]
  expect_equals "A" a.name
  expect_equals "I1" i1.name
  expect_equals "B" b.name

  expect_not_null b.superclass
  super_ref := b.superclass
  super_class := summary.toplevel_element_with_id super_ref.id
  expect_equals "A" super_class.name
  expect_equals super_ref.id super_class.toplevel_id
