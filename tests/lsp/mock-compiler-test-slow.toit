// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Tests the mock compiler.

import .lsp-client show LspClient run-client-test
import .mock-compiler
import host.directory
import expect show *

main args:
  run-client-test args --use-mock: test it

test client/LspClient:
  mock-compiler := MockCompiler client

  path1 := "/tmp/path1.toit"
  path2 := "/tmp/path2.toit"

  path1-diagnostics := [
    MockDiagnostic --path=path1 "Unresolved identifier: 'foo' RESPONSE FROM MOCK" 1 2 1 5,
  ]
  path1-deps := []
  path1-mock-data := MockData path1-diagnostics path1-deps
  mock-compiler.set-mock-data --path=path1 path1-mock-data

  print "sending mock for analyze"
  answer := mock-compiler.build-analysis-answer --path=path1
  mock-compiler.set-analysis-result answer

  print "using the mock"
  client.send-did-open --path=path1 --text="""
    main:  // Content here is completely ignored.
      foo
    """

  diagnostics := client.diagnostics-for --path=path1
  expect-equals 1 diagnostics.size
  expect (path1-diagnostics[0].is-same-as-json diagnostics[0])
  expect-null (client.diagnostics-for --path=path2)

  // Changing the DEPS doesn't make a difference here.
  path1-mock-data.deps = [path2]
  // We don't need to set the data again, as it wasn't copied, but it doesn't hurt.
  mock-compiler.set-mock-data --path=path1 path1-mock-data
  answer = mock-compiler.build-analysis-answer --path=path1
  mock-compiler.set-analysis-result answer

  client.send-did-change --path=path1 """
    main:  // Content here is completely ignored.
      foo2
    """

  diagnostics = client.diagnostics-for --path=path1
  expect-equals 1 diagnostics.size
  expect (path1-diagnostics[0].is-same-as-json diagnostics[0])

  diagnostics = client.diagnostics-for --path=path2
  // Since the file was now listed in the dependencies we get the information that
  // there aren't any errors in it.
  expect-not-null diagnostics
