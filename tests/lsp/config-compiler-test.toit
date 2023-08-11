// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import host.directory
import expect show *
import host.file
import monitor

SETTINGS-KEY ::= "someConfig"
SETTINGS-VALUE ::= "toit"

main args:
  run-client-test
      args
      --pre-initialize=: it.configuration[SETTINGS-KEY] = SETTINGS-VALUE:
    test it --supports-config

  run-client-test
      args
      --no-supports-config
      --pre-initialize=: it.configuration[SETTINGS-KEY] = SETTINGS-VALUE:
    test it --no-supports-config

test client/LspClient --supports-config/bool:
  // Open a document first, so that the server has time to fetch the config from the client.
  // Otherwise we end up in some sort of race condition.
  client.send-did-open --uri="untitled:Untitled0" --text=""

  settings := client.send-request "toit/settings" null
  if supports-config:
    expect-equals SETTINGS-VALUE settings[SETTINGS-KEY]
  else:
    expect (not settings.contains SETTINGS-KEY)
