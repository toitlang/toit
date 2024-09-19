// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import host.directory
import expect show *
import host.file
import monitor

main args:
  run-client-test
      args
      --supports-config
      --needs-server-args
      --pre-initialize=: it.configuration = null:
    test it --no-supports-config

test client/LspClient --supports-config/bool:
  uri := "untitled:Untitled0"
  client.send-did-open --uri=uri --text="""
  main:
    print 1 2
  """
  expect-equals 1 (client.diagnostics-for --uri=uri).size
