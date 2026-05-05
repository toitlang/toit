// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.pipe
import system

import .utils
import ...tools.lsp.server.client show with-lsp-client LspClient

main args:
  toit-exe := ToitExecutable args

  toit-binary := args[0]

  server-cmd := toit-binary
  server-args := ["tool", "lsp"]
  client := LspClient.start
      server-cmd
      server-args
      --no-supports-config
      --compiler-exe=null
      --spawn-process
  client.initialize
  client.send-shutdown
  client.send-exit
