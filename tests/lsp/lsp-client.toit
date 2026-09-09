// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ...tools.lsp.server.client show with-lsp-client LspClient
import .mock-compiler show MockCompiler
import host.directory
import host.os
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
    --exit=true
    --spawn-process=true
    [--pre-initialize]:
  run-client-test_
      args
      --supports-config=supports-config
      --needs-server-args=needs-server-args
      --spawn-process=spawn-process
      --no-use-mock
      --pre-initialize=pre-initialize:
    | client _ | test-fun.call client

/** See [run_client_test] above. */
run-client-test
    args
    [test-fun]
    --supports-config=true
    --needs-server-args=(not supports-config)
    --exit=true
    --spawn-process=true
    --use-toitlsp=false:
  run-client-test_
      args
      --supports-config=supports-config
      --needs-server-args=needs-server-args
      --spawn-process=spawn-process
      --no-use-mock
      --pre-initialize=(: null):
    | client _ | test-fun.call client

/**
Variant of $run-client-test that runs the server with the mock compiler.

The block receives the client and the $MockCompiler that controls the mock
  compiler. The mock compiler is closed when the block returns.
*/
run-client-test
    args
    [test-fun]
    --use-mock/True
    --supports-config=true
    --needs-server-args=(not supports-config)
    --spawn-process=true
    [--pre-initialize]:
  run-client-test_
      args
      --supports-config=supports-config
      --needs-server-args=needs-server-args
      --spawn-process=spawn-process
      --use-mock
      --pre-initialize=pre-initialize:
    | client mock-compiler | test-fun.call client mock-compiler

/** See $run-client-test above. */
run-client-test
    args
    [test-fun]
    --use-mock/True
    --supports-config=true
    --needs-server-args=(not supports-config)
    --spawn-process=true:
  run-client-test_
      args
      --supports-config=supports-config
      --needs-server-args=needs-server-args
      --spawn-process=spawn-process
      --use-mock
      --pre-initialize=(: null):
    | client mock-compiler | test-fun.call client mock-compiler

/**
Runs the given [test_fun] with the client and, if [use_mock] is true, the
  $MockCompiler that controls the mock compiler. Otherwise the second
  argument is null.
*/
run-client-test_
    args
    [test-fun]
    --supports-config/bool
    --needs-server-args/bool
    --spawn-process/bool
    --use-mock/bool
    [--pre-initialize]:
  toit := args[0]
  lsp-server := args[1]
  mock-compiler-exe := args[2]

  compiler-exe := toit
  mock-compiler/MockCompiler? := null
  if use-mock:
    compiler-exe = mock-compiler-exe
    mock-compiler = MockCompiler
    // The mock compiler finds the test through the environment of the server,
    // so the port must be set before the server is spawned.
    os.env[MockCompiler.PORT-ENVIRONMENT-VARIABLE] = "$mock-compiler.port"

  repro-dir := directory.mkdtemp "/tmp/lsp_repro-"
  try:
    with-lsp-client
        --toit=toit
        --lsp-server=lsp-server
        --compiler-exe=compiler-exe
        --supports-config=supports-config
        --needs-server-args=needs-server-args
        --spawn-process=spawn-process
        --pre-initialize=(: | client args |
            client.configuration["reproDir"] = repro-dir
            // Tests send a 'didChange' and then immediately wait for the
            // analysis. Don't make them wait for the debounce.
            client.configuration["analysisDebounceMs"] = 0
            pre-initialize.call client args):
      test-fun.call it mock-compiler
  finally:
    directory.rmdir --recursive repro-dir
    if mock-compiler: mock-compiler.close
