// Copyright (C) 2019 Toitware ApS. All rights reserved.

// Tests the mock compiler.

import .lsp_client show LspClient run_client_test
import .mock_compiler
import host.directory
import expect show *

// TODO(jesper): Remove slow tag once toit lsp implementation is gone.
main args:
  run_client_test args --use_mock: test it
  run_client_test args --use_toitlsp --use_mock: test it

test client/LspClient:
  mock_compiler := MockCompiler client

  path1 := "/tmp/path1.toit"
  path2 := "/tmp/path2.toit"

  path1_diagnostics := [
    MockDiagnostic --path=path1 "Unresolved identifier: 'foo' RESPONSE FROM MOCK" 1 2 1 5,
  ]
  path1_deps := []
  path1_mock_data := MockData path1_diagnostics path1_deps
  mock_compiler.set_mock_data --path=path1 path1_mock_data

  print "sending mock for analyze"
  answer := mock_compiler.build_analysis_answer --path=path1
  mock_compiler.set_analysis_result answer

  print "using the mock"
  client.send_did_open --path=path1 --text="""
    main:  // Content here is completely ignored.
      foo
    """

  diagnostics := client.diagnostics_for --path=path1
  expect_equals 1 diagnostics.size
  expect (path1_diagnostics[0].is_same_as_json diagnostics[0])
  expect_null (client.diagnostics_for --path=path2)

  // Changing the DEPS doesn't make a difference here.
  path1_mock_data.deps = [path2]
  // We don't need to set the data again, as it wasn't copied, but it doesn't hurt.
  mock_compiler.set_mock_data --path=path1 path1_mock_data
  answer = mock_compiler.build_analysis_answer --path=path1
  mock_compiler.set_analysis_result answer

  client.send_did_change --path=path1 """
    main:  // Content here is completely ignored.
      foo2
    """

  diagnostics = client.diagnostics_for --path=path1
  expect_equals 1 diagnostics.size
  expect (path1_diagnostics[0].is_same_as_json diagnostics[0])

  diagnostics = client.diagnostics_for --path=path2
  // Since the file was now listed in the dependencies we get the information that
  // there aren't any errors in it.
  expect_not_null diagnostics
