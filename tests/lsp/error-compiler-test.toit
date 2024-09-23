// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import .mock-compiler
import expect show *

main args:
  run-client-test args --use-mock: test it --error-handler-path="window/showMessage"
  run-client-test args
      --use-mock
      --pre-initialize=: it.configuration["shouldWriteReproOnCrash"] = false:
    test it --error-handler-path="window/logMessage"

test client/LspClient --error-handler-path/string:
  mock-compiler := MockCompiler client

  UNEXPECTED-ERROR-LINE ::= "unexpected line that should be reported as error"

  message := null
  client.install-handler error-handler-path::
    message = it["message"]

  path := "/tmp/path.toit"
  path-diagnostics := []
  path-deps := []

  path-mock-data := MockData path-diagnostics path-deps
  mock-compiler.set-mock-data --path=path path-mock-data

  print "sending mock for analyze"
  answer := mock-compiler.build-analysis-answer --path=path
  answer += "\n$UNEXPECTED-ERROR-LINE\n"
  mock-compiler.set-analysis-result answer

  print "using the mock"
  client.send-did-open --path=path --text="""\
    main:  // Content here is completely ignored.
      foo
    """

  expect-not-null message
  expect (message.contains UNEXPECTED-ERROR-LINE)
