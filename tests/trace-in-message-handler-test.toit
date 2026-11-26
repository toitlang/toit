// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
A process keeps processing its messages after the handler of an RPC request
  throws.

The RPC requests and replies are handled inline, in the task that processes
  the messages, and the exception of a handler is traced. Sending the trace
  looked up the trace service through RPC, and the reply to that call can
  only be taken from the mailbox by the message processing that is waiting
  for it. The process stopped processing messages, timers included.
*/

import expect show *
import monitor
import rpc
import rpc.broker show RpcBroker

PROCEDURE-READY ::= 620
PROCEDURE-ECHO  ::= 621
PROCEDURE-STOP  ::= 622

class FailingBroker extends RpcBroker:
  failures := 1

  accept gid/int pid/int -> bool:
    if failures > 0:
      failures--
      throw "ACCEPT FAILED"
    return true

main:
  broker := RpcBroker
  broker.install
  ready := monitor.Latch
  broker.register-procedure PROCEDURE-READY:: | _ gid pid | ready.set pid
  parent := Process.current.id
  spawn:: provider parent
  provider-pid := with-timeout --ms=10_000: ready.get

  // The provider's 'accept' throws for this request, which is dropped.
  expect-throw DEADLINE-EXCEEDED-ERROR:
    with-timeout --ms=200: rpc.invoke provider-pid PROCEDURE-ECHO 1
  // The provider still answers.
  expect-equals 2
      with-timeout --ms=10_000: rpc.invoke provider-pid PROCEDURE-ECHO 2
  rpc.invoke provider-pid PROCEDURE-STOP null

provider parent/int -> none:
  stop := monitor.Latch
  broker := FailingBroker
  broker.register-procedure PROCEDURE-ECHO:: | arguments | arguments
  broker.register-procedure PROCEDURE-STOP:: stop.set true
  broker.install
  rpc.invoke parent PROCEDURE-READY null
  stop.get
