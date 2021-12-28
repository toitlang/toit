// Copyright (C) 2019 Toitware ApS. All rights reserved.

import .lsp_client show LspClient run_client_test
import .mock_compiler
import expect show *

main args:
  run_client_test args --use_mock: test it --error_handler_path="window/showMessage"
  run_client_test --use_toitlsp args --use_mock: test it --error_handler_path="window/showMessage"
  run_client_test args
      --use_mock
      --pre_initialize=: it.configuration["shouldWriteReproOnCrash"] = false:
    test it --error_handler_path="window/logMessage"
  run_client_test --use_toitlsp args
      --use_mock
      --pre_initialize=: it.configuration["shouldWriteReproOnCrash"] = false:
    test it --error_handler_path="window/logMessage"

test client/LspClient --error_handler_path/string:
  mock_compiler := MockCompiler client

  UNEXPECTED_ERROR_LINE ::= "unexpected line that should be reported as error"

  message := null
  client.install_handler error_handler_path::
    message = it["message"]

  path := "/tmp/path.toit"
  path_diagnostics := []
  path_deps := []

  path_mock_data := MockData path_diagnostics path_deps
  mock_compiler.set_mock_data --path=path path_mock_data

  print "sending mock for analyze"
  answer := mock_compiler.build_analysis_answer --path=path
  answer += "\n$UNEXPECTED_ERROR_LINE\n"
  mock_compiler.set_analysis_result answer

  print "using the mock"
  client.send_did_open --path=path --text="""\
    main:  // Content here is completely ignored.
      foo
    """

  expect_not_null message
  expect (message.contains UNEXPECTED_ERROR_LINE)
