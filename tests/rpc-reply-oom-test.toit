// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
An RPC client that runs out of memory while it handles a reply gets an
  exception, instead of waiting for the reply forever.

The client runs in a process with a small heap and grows a ballast list
  until allocations fail, so it is out of memory at many different points
  of its RPC calls. When the reply handler (Rpc.on-message, run by the task
  that processes the messages; here the waiting caller itself) ran out of
  memory, the reply had already been taken from the mailbox, and the
  exception was swallowed by the message processing: the caller waited for
  a reply that was gone, forever. Now the OUT_OF_MEMORY of a reply handler
  goes to the processing task, as a failed decode of the message does.

The driver checks that the client keeps making progress through many
  out-of-memory episodes, and fails if it stops making progress.
*/

import expect show *
import system.services

interface TestService:
  static SELECTOR ::= services.ServiceSelector
      --uuid="0f3a5c2e-8d71-4b6a-9e40-2c1d7b8a6f53"
      --major=1
      --minor=0
  echo value/any -> any
  static ECHO-INDEX ::= 0
  report stats/List -> none
  static REPORT-INDEX ::= 1

class TestClient extends services.ServiceClient implements TestService:
  static SELECTOR ::= TestService.SELECTOR
  constructor selector/services.ServiceSelector=SELECTOR:
    super selector
  echo value/any -> any: return invoke_ TestService.ECHO-INDEX value
  report stats/List -> none: invoke_ TestService.REPORT-INDEX stats

class TestProvider extends services.ServiceProvider implements services.ServiceHandler:
  iterations := 0
  ooms := 0
  constructor:
    super "test/rpc-reply-oom" --major=1 --minor=0
    provides TestService.SELECTOR --handler=this
  handle index/int arguments/any --gid/int --client/int -> any:
    if index == TestService.ECHO-INDEX: return arguments
    if index == TestService.REPORT-INDEX:
      iterations = arguments[0]
      ooms = arguments[1]
      return null
    unreachable

HEAP ::= 100_000
RUN-MS ::= 20_000
STALL-MS ::= 4_000
// Without the fix the client blocked at one of its first episodes (the
// 15th on x64 Linux).
OOMS ::= 100

run-client -> none:
  set-max-heap-size_ HEAP
  client := TestClient
  client.open
  ballast := []
  iterations := 0
  ooms := 0
  while ooms < OOMS:
    iterations++
    exception := catch:
      payload := ByteArray 512 + (iterations * 37) % 512: it
      echoed := client.echo payload
      expect-equals payload.size echoed.size
      ballast.add (ByteArray 700)
    if exception == "OUT_OF_MEMORY":
      ooms++
      ballast = ballast[ballast.size / 2..].copy
    else if exception:
      print "client: unexpected $exception"
      return
    if iterations % 10 == 0 or ooms == OOMS:
      catch: client.report [iterations, ooms]
  ballast = []
  // The last report may have hit the out-of-memory condition too.
  client.report [iterations, ooms]
  client.close

main:
  provider := TestProvider
  provider.install
  spawn:: run-client
  deadline := Time.monotonic-us + RUN-MS * 1000
  last := -1
  last-change := Time.monotonic-us
  while Time.monotonic-us < deadline and provider.ooms < OOMS:
    sleep --ms=100
    if provider.iterations != last:
      last = provider.iterations
      last-change = Time.monotonic-us
    else if Time.monotonic-us - last-change > STALL-MS * 1000:
      break
  print "iterations $provider.iterations, out of memory $provider.ooms times"
  // Fails while the client is blocked (and ends the test).
  expect-equals OOMS provider.ooms
  provider.uninstall
