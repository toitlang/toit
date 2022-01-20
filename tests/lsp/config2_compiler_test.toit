// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp_client show LspClient run_client_test
import host.directory
import expect show *
import host.file
import monitor

main args:
  run_client_test
      args
      --supports_config
      --needs_server_args
      --pre_initialize=: it.configuration = null:
    test it --no-supports_config

  run_client_test
      --use_toitlsp
      args
      --supports_config
      --needs_server_args
      --pre_initialize=: it.configuration = null:
    test it --no-supports_config

test client/LspClient --supports_config/bool:
  uri := "untitled:Untitled0"
  client.send_did_open --uri=uri --text="""
  main:
    print 1 2
  """
  expect_equals 1 (client.diagnostics_for --uri=uri).size
