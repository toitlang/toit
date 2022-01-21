// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ...tools.lsp.server.client show with_lsp_client LspClient
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
run_client_test
    args
    [test_fun]
    --supports_config=true
    --needs_server_args=(not supports_config)
    --use_rpc_filesystem=false
    --use_mock=false
    --exit=true
    --spawn_process=true
    --use_toitlsp=false
    [--pre_initialize]:
  toitc := args[0]
  lsp_server := args[1]
  mock_compiler := args[2]

  toitlsp_exe := null
  if use_toitlsp:
    toitlsp_exe = args[3]

  compiler_exe := use_mock ? mock_compiler : toitc

  repro_dir := directory.mkdtemp "/tmp/lsp_repro-"
  try:
    with_lsp_client test_fun
        --toitc=toitc
        --lsp_server=lsp_server
        --compiler_exe=compiler_exe
        --toitlsp_exe=toitlsp_exe
        --supports_config=supports_config
        --needs_server_args=needs_server_args
        --use_rpc_filesystem=use_rpc_filesystem
        --spawn_process=spawn_process
        --pre_initialize=: | client args |
            client.configuration["reproDir"] = repro_dir
            pre_initialize.call client args
  finally:
    directory.rmdir --recursive repro_dir

/** See [run_client_test] above. */
run_client_test
    args
    [test_fun]
    --supports_config=true
    --needs_server_args=(not supports_config)
    --use_rpc_filesystem=false
    --use_mock=false
    --exit=true
    --spawn_process=true
    --use_toitlsp=false:
  run_client_test
      args
      test_fun
      --supports_config=supports_config
      --needs_server_args=needs_server_args
      --use_rpc_filesystem=use_rpc_filesystem
      --pre_initialize=: null
      --use_mock=use_mock
      --spawn_process=spawn_process
      --use_toitlsp=use_toitlsp
