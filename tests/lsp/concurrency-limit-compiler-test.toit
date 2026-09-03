// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Tests that the number of concurrently running compilers is limited.

import .lsp-client show LspClient run-client-test
import .mock-compiler
import expect show *
import monitor

REQUEST-COUNT ::= 6
COMPILER-DELAY-US ::= 300_000

main args:
  // Run the same batch of requests with a limit that serializes them, with a
  // limit that lets all of them run at the same time, and without any limit.
  serialized-ms := measure args --max-concurrent=1
  concurrent-ms := measure args --max-concurrent=REQUEST-COUNT
  unlimited-ms := measure args --max-concurrent=0
  print "serialized: $(serialized-ms)ms, concurrent: $(concurrent-ms)ms, unlimited: $(unlimited-ms)ms"
  // Serialized, the requests take REQUEST-COUNT times as long. Be generous
  // with the factor, so that a loaded machine doesn't make the test flaky.
  expect serialized-ms > concurrent-ms * 2
  expect serialized-ms > unlimited-ms * 2

measure args --max-concurrent/int -> int:
  result := 0
  run-client-test
      args
      --use-mock
      --pre-initialize=: it.configuration["maxConcurrentCompilers"] = max-concurrent:
    result = run-requests it
  return result

run-requests client/LspClient -> int:
  mock-compiler := MockCompiler client

  uri := "untitled:Untitled-1"
  path := client.to-path uri

  mock-compiler.set-mock-data --path=path (MockData [] [])
  mock-compiler.set-analysis-result (mock-compiler.build-analysis-answer --path=path)
  client.send-did-open --uri=uri --text="Ignored content"

  // Every completion request runs a compiler that takes $COMPILER-DELAY-US.
  mock-compiler.set-completion-result
      "SLOW\n$COMPILER-DELAY-US\n\n0\n0\n0\n0\nfoo\n-1\nbar\n-1\n"

  // The requests must overlap, so we must not wait for idle in between.
  client.always-wait-for-idle = false
  done := monitor.Semaphore
  start := Time.monotonic-us
  REQUEST-COUNT.repeat:
    task:: catch --trace:
      completions := client.send-completion-request --uri=uri 1 2
      expect-equals 2 completions.size
      done.up
  REQUEST-COUNT.repeat: done.down
  elapsed-ms := (Time.monotonic-us - start) / 1000

  client.always-wait-for-idle = true
  client.wait-for-idle
  return elapsed-ms
