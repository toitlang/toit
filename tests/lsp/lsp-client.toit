// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ...tools.lsp.server.client show with-lsp-client LspClient
import host.directory
export LspClient

/**
Spawns an LSP client and runs the given [test_fun].
The client is given as argument to the block.
Once the block returns invokes a shutdown, and (if spawned in a process) an exit.

For debugging set [spawn_process] to false, so that the lsp server is launched
  in the same process as the test. This is also necessary, when changing
  variables inside the LSP server. When not spawning a process, the test must exit with
  `exit` as some processes keep the test alive.

The [pre_initialize] block is executed with an instantiated client, before the
  'initialize' call to the server. The callback may change the client's configuration
  at that time.
*/
run-client-test
    args
    [test-fun]
    --supports-config=true
    --needs-server-args=(not supports-config)
    --use-mock=false
    --exit=true
    --spawn-process=true
    [--pre-initialize]:
  toit := args[0]
  lsp-server := args[1]
  mock-compiler := args[2]

  compiler-exe := use-mock ? mock-compiler : toit

  repro-dir := directory.mkdtemp "/tmp/lsp_repro-"
  try:
    with-lsp-client test-fun
        --toit=toit
        --lsp-server=lsp-server
        --compiler-exe=compiler-exe
        --supports-config=supports-config
        --needs-server-args=needs-server-args
        --spawn-process=spawn-process
        --pre-initialize=: | client args |
            client.configuration["reproDir"] = repro-dir
            pre-initialize.call client args
  finally:
    directory.rmdir --recursive repro-dir

/** See [run_client_test] above. */
run-client-test
    args
    [test-fun]
    --supports-config=true
    --needs-server-args=(not supports-config)
    --use-mock=false
    --exit=true
    --spawn-process=true
    --use-toitlsp=false:
  run-client-test
      args
      test-fun
      --supports-config=supports-config
      --needs-server-args=needs-server-args
      --pre-initialize=: null
      --use-mock=use-mock
      --spawn-process=spawn-process
