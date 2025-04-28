// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import ...tools.lsp.server.summary
import ...tools.lsp.server.toitdoc-node
import .utils
import system
import system show platform

import host.directory
import expect show *

main args:
  // We are reaching into the server, so we must not spawn the server as
  // a process.
  run-client-test args --no-spawn-process: test it
  // Since we used '--no-spawn-process' we must exit 0.
  exit 0

DRIVE ::= platform == system.PLATFORM-WINDOWS ? "c:" : ""
FILE-PATH ::= "$DRIVE/tmp/file.toit"

test client/LspClient:
  client.send-did-open --path=FILE-PATH --text=""

  client.send-did-change --path=FILE-PATH """
    class NotImportant:  // ID: 0
    class A:
    interface I1:
    class B extends A implements I1:
    """
  uri := client.to-uri FILE-PATH
  project-uri := client.server.documents_.project-uri-for --uri=uri
  analyzed-documents := client.server.documents_.analyzed-documents-for --project-uri=project-uri

  document := analyzed-documents.get-existing --uri=uri
  summary := document.summary
  classes := summary.classes

  expect-equals 4 classes.size
  not-important /Class := classes[0]
  a /Class := classes[1]
  i1 /Class := classes[2]
  b /Class := classes[3]
  expect-equals "A" a.name
  expect-equals "I1" i1.name
  expect-equals "B" b.name

  expect-not-null b.superclass
  super-ref := b.superclass
  super-class := summary.toplevel-element-with-id super-ref.id
  expect-equals "A" super-class.name
  expect-equals super-ref.id super-class.toplevel-id
