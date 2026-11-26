// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
An RPC client gets a reply or an error, instead of waiting forever, when the
  provider runs out of memory.

The provider runs in a process with a small heap and grows a ballast list
  until allocations fail, so it is out of memory at many points while it
  takes requests from its mailbox, enqueues them, runs the procedure, builds
  the reply and sends it. A request or reply that was lost at one of these
  points used to leave its client waiting forever (found by the soak tests
  of a sandboxed ESP32).

The client gives each call a deadline and checks that every call gets its
  reply or fails with an out-of-memory error, over many out-of-memory
  episodes of the provider.
*/

import expect show *
import monitor
import rpc
import rpc.broker show RpcBroker

PROCEDURE-ECHO ::= 700
PROCEDURE-READY ::= 701
PROCEDURE-STOP ::= 702

HEAP ::= 100_000
CALLS ::= 1_000
DEADLINE-MS ::= 20_000
// Out-of-memory episodes of the provider the test needs to see.
EPISODES ::= 30
OUT-OF-MEMORY-ERRORS ::= ["OUT_OF_MEMORY", "MALLOC_FAILED", "ALLOCATION_FAILED"]

main:
  broker := RpcBroker
  broker.install
  ready := monitor.Latch
  broker.register-procedure PROCEDURE-READY:: | args |
    ready.set args[0]
    null
  myself := Process.current.id
  spawn:: provider-main myself
  provider := ready.get

  replies := 0
  errors := 0
  CALLS.repeat: | n |
    payload := ByteArray 256 + (n * 37) % 768: it
    exception := catch:
      result := with-timeout --ms=DEADLINE-MS:
        rpc.invoke provider PROCEDURE-ECHO payload
      expect-equals payload.size result.size
      replies++
    if exception == "NO_SUCH_PROCESS":
      print "OUTCOME died after $n calls ($replies replies, $errors errors)"
      return
    if exception == DEADLINE-EXCEEDED-ERROR:
      // Is the provider still there and answering?
      probe := catch: with-timeout --ms=DEADLINE-MS: rpc.invoke provider PROCEDURE-ECHO #[1]
      kind := probe == null ? "lost" : (probe == "NO_SUCH_PROCESS" ? "died-during" : "stuck")
      print "OUTCOME $kind at call $n ($replies replies, $errors errors)"
      exit 1
    if exception:
      expect (OUT-OF-MEMORY-ERRORS.contains exception)
      errors++
  episodes := rpc.invoke provider PROCEDURE-STOP []
  print "OUTCOME ok: replies $replies, out-of-memory errors $errors, provider episodes $episodes"

provider-main client/int -> none:
  set-max-heap-size_ HEAP
  broker := RpcBroker
  broker.install
  episodes := 0
  stopped := false
  broker.register-procedure PROCEDURE-ECHO:: | args |
    // Keeps a copy for a while: the procedure allocates too.
    copy := args.copy
    copy
  broker.register-procedure PROCEDURE-STOP:: | args |
    stopped = true
    episodes
  rpc.invoke client PROCEDURE-READY [Process.current.id]
  ballast/List? := null
  while not stopped:
    exception := catch:
      if not ballast: ballast = []
      ballast.add (ByteArray 2_000)
      yield
    if exception:
      episodes++
      // Dropped without a call: freeing it must not need memory (a
      // deeper stack) itself.
      ballast = null
