// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp_client show LspClient run_client_test
import host.directory
import expect show *
import host.file
import monitor

SETTINGS_KEY ::= "someConfig"
SETTINGS_VALUE ::= "toit"

main args:
  run_client_test
      args
      --pre_initialize=: it.configuration[SETTINGS_KEY] = SETTINGS_VALUE:
    test it --supports_config

  run_client_test
      args
      --no-supports_config
      --pre_initialize=: it.configuration[SETTINGS_KEY] = SETTINGS_VALUE:
    test it --no-supports_config

test client/LspClient --supports_config/bool:
  // Open a document first, so that the server has time to fetch the config from the client.
  // Otherwise we end up in some sort of race condition.
  client.send_did_open --uri="untitled:Untitled0" --text=""

  settings := client.send_request "toit/settings" null
  if supports_config:
    expect_equals SETTINGS_VALUE settings[SETTINGS_KEY]
  else:
    expect (not settings.contains SETTINGS_KEY)
