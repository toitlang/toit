// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
A provider whose request handler runs out of memory answers the request with
  an OUT_OF_MEMORY error, unless the request was enqueued before (then it
  is answered as usual). Neither case throws into the provider's tasks.

The out-of-memory errors are injected as in rpc-oom-liveness-test.toit, by a
  wrapper of the provider's request handler that also passes on the
  out-of-memory callback of the real handler (RpcBroker).
*/

import expect show *
import monitor
import rpc
import rpc.broker show RpcBroker

PROCEDURE-ECHO ::= 610
PROCEDURE-READY ::= 611
PROCEDURE-CONTROL ::= 612

DEADLINE-MS ::= 3_000

class FailingHandler implements SystemMessageHandler_ SystemMessageOutOfMemoryHandler_:
  inner/RpcBroker
  before/int := 0
  after/int := 0

  constructor .inner:

  on-message type gid pid message -> none:
    if type == SYSTEM-RPC-REQUEST_ and before > 0:
      before--
      throw "OUT_OF_MEMORY"
    inner.on-message type gid pid message
    if type == SYSTEM-RPC-REQUEST_ and after > 0:
      after--
      throw "OUT_OF_MEMORY"

  on-out-of-memory type gid pid message -> none:
    inner.on-out-of-memory type gid pid message

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

  // Fails before it is enqueued: an OUT_OF_MEMORY error reply.
  rpc.invoke provider PROCEDURE-CONTROL ["fail-before"]
  expect-throw "OUT_OF_MEMORY": call provider "before"
  // Fails after it was enqueued: answered as usual.
  rpc.invoke provider PROCEDURE-CONTROL ["fail-after"]
  expect-equals "after" (call provider "after")
  expect-equals "next" (call provider "next")
  // [echo calls served, errors the provider's main task got]: the
  // procedure ran for "after" and "next" only, and the provider's tasks got
  // no error.
  expect-equals [2, 0] (rpc.invoke provider PROCEDURE-CONTROL ["stop"])

call pid/int value/any -> any:
  return with-timeout --ms=DEADLINE-MS:
    rpc.invoke pid PROCEDURE-ECHO value

provider-main client/int -> none:
  broker := RpcBroker
  broker.install
  handler := FailingHandler broker
  set-system-message-handler_ SYSTEM-RPC-REQUEST_ handler
  echoes := 0
  errors := 0
  stopped := false
  broker.register-procedure PROCEDURE-ECHO:: | args |
    echoes++
    args
  broker.register-procedure PROCEDURE-CONTROL:: | args |
    if args[0] == "fail-before": handler.before = 1
    if args[0] == "fail-after": handler.after = 1
    if args[0] == "stop": stopped = true
    [echoes, errors]
  rpc.invoke client PROCEDURE-READY [Process.current.id]
  while not stopped:
    exception := catch: sleep --ms=10
    if exception: errors++
