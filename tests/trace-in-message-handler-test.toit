// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
A process whose system message handler throws keeps running.

The message processing traces the exception of a handler. Sending a trace
  looked up the trace service through RPC, and an RPC call made while the
  process processes its messages waits for a reply that only that message
  processing could take from the mailbox: the process stopped processing
  messages for good, timers included. Now such traces go to the system
  process directly.
*/

import expect show *
import monitor
import rpc
import rpc.broker show RpcBroker

PROCEDURE-ECHO ::= 620
PROCEDURE-RESULT ::= 621

class ThrowingHandler implements SystemMessageHandler_:
  inner/SystemMessageHandler_
  throws := 1
  constructor .inner:
  on-message type gid pid message -> none:
    if throws > 0:
      throws--
      throw "BROKEN HANDLER"
    inner.on-message type gid pid message

main:
  broker := RpcBroker
  broker.install
  result := monitor.Latch
  broker.register-procedure PROCEDURE-ECHO:: | args | args
  broker.register-procedure PROCEDURE-RESULT:: | args |
    result.set args[0]
    null
  myself := Process.current.id
  spawn:: child myself
  expect-equals "alive" (with-timeout --ms=10_000: result.get)

child parent/int -> none:
  // Sets up the RPC machinery (the reply handler) before wrapping it.
  expect-equals 1 (rpc.invoke parent PROCEDURE-ECHO 1)
  set-system-message-handler_ SYSTEM-RPC-REPLY_
      ThrowingHandler system-message-handlers_[SYSTEM-RPC-REPLY_]
  // The handler throws on this reply: the reply is lost and the call
  // reaches its deadline.
  expect-throw DEADLINE-EXCEEDED-ERROR:
    with-timeout --ms=200: rpc.invoke parent PROCEDURE-ECHO 2
  // The process still processes its messages.
  expect-equals 3 (rpc.invoke parent PROCEDURE-ECHO 3)
  rpc.invoke parent PROCEDURE-RESULT ["alive"]
