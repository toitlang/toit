// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
An RPC call doesn't wait forever when a process runs out of memory while it
  handles the call's request or reply: the message is handled again later,
  so the call gets its reply (or fails with OUT_OF_MEMORY).

The messages are taken from the mailbox before their handlers run. A handler
  that ran out of memory (it could not grow the processing task's stack, or
  allocate) used to lose the message: a lost reply left its caller waiting
  forever when another task than the caller processed it (the caller itself
  got the error since 1a19d3df), and a lost request left its client waiting
  forever (found by the soak tests of a sandboxed ESP32).

The out-of-memory errors are injected: the system message handlers are
  wrapped with handlers that throw OUT_OF_MEMORY once, before or after the
  real handler, which is what a handler that runs out of memory does. Each
  call has a deadline: a call that waits forever fails the test.

Cases:
- a reply handled by another task than the caller, which gets the error;
- a reply handled by a task that is ending (its error used to end the
  process);
- a request lost at the provider, a process of its own whose task that
  processes the messages gets the error;
- a request that ran out of memory after it was enqueued is answered once
  (it must not be enqueued again when it is handled again).
*/

import expect show *
import monitor
import rpc
import rpc.broker show RpcBroker

PROCEDURE-ECHO ::= 600
PROCEDURE-READY ::= 601
PROCEDURE-COUNT ::= 602
PROCEDURE-RESULT ::= 603

DEADLINE-MS ::= 3_000

/**
Wraps the system message handler of one type. Throws OUT_OF_MEMORY on the
  next $before messages before the real handler runs and on the next $after
  messages after it ran.
*/
class FailingHandler implements SystemMessageHandler_:
  inner/SystemMessageHandler_
  before/int := 0
  after/int := 0
  thrown/int := 0

  constructor .inner:

  on-message type gid pid message -> none:
    if before > 0:
      before--
      thrown++
      throw "OUT_OF_MEMORY"
    inner.on-message type gid pid message
    if after > 0:
      after--
      thrown++
      throw "OUT_OF_MEMORY"

wrap type/int -> FailingHandler:
  handler := FailingHandler system-message-handlers_[type]
  set-system-message-handler_ type handler
  return handler

main:
  // The test runs in two processes of their own (the client and the
  // provider), not in this one, the boot process (which, on a device, is the
  // system process).
  broker := RpcBroker
  broker.install
  provider-ready := monitor.Latch
  result := monitor.Latch
  broker.register-procedure PROCEDURE-READY:: | args |
    provider-ready.set args[0]
    null
  broker.register-procedure PROCEDURE-RESULT:: | args |
    result.set args[0]
    null
  myself := Process.current.id
  spawn:: provider-main myself
  provider := provider-ready.get
  spawn:: client-main myself provider
  // Fails if the client got stuck (or failed).
  expect-equals "ok" (with-timeout --ms=4 * DEADLINE-MS: result.get)
  rpc.invoke provider PROCEDURE-COUNT ["stop", 0]

client-main coordinator/int provider/int -> none:
  // Makes sure the RPC machinery of this process is set up (Rpc.instance
  // registers the reply handler) before the reply handler is wrapped.
  expect-equals 7 (call provider 7)
  replies := wrap SYSTEM-RPC-REPLY_

  test-reply-other-task provider replies
  test-reply-ending-task provider replies
  test-request-provider provider
  test-request-after-enqueue provider
  rpc.invoke coordinator PROCEDURE-RESULT ["ok"]

call pid/int value/any -> any:
  return with-timeout --ms=DEADLINE-MS:
    rpc.invoke pid PROCEDURE-ECHO value

/**
The reply is handled by another task than the caller, and its handler runs
  out of memory. That task gets the error; the reply is handled again, and
  the caller gets it.
*/
test-reply-other-task provider/int replies/FailingHandler -> none:
  replies.before = 1
  done := false
  errors := 0
  // Keeps running, so that the caller suspends (it isn't the last running
  // task) and this task processes the messages when it yields.
  helper := task::
    while not done:
      exception := catch: yield
      if exception:
        expect-equals "OUT_OF_MEMORY" exception
        errors++
  expect-equals "other task" (call provider "other task")
  done = true
  expect-equals 1 replies.thrown
  // The helper got the error; the reply was kept and handled again.
  expect-equals 1 errors
  replies.thrown = 0

/**
The reply is handled by a task that is ending (tasks process the messages
  before they end), and its handler runs out of memory. The ending task
  doesn't end the process with the error: the reply is handled again and the
  caller gets it.
*/
test-reply-ending-task provider/int replies/FailingHandler -> none:
  replies.before = 1
  // Ends as soon as the reply has arrived, without processing it before.
  task::
    while not task-has-messages_: null
  expect-equals "ending task" (call provider "ending task")
  expect-equals 1 replies.thrown
  replies.thrown = 0

/**
The request is handled by the provider's task that processes the messages,
  and the request handler runs out of memory before it enqueued the request.
  That task (the provider's main task or one of its RPC processing tasks,
  which process the messages while they wait) gets the error; the request
  is handled again and answered.
*/
test-request-provider provider/int -> none:
  thrown := (rpc.invoke provider PROCEDURE-COUNT ["counts", 0])[0]
  rpc.invoke provider PROCEDURE-COUNT ["fail-before", 1]
  expect-equals "provider" (call provider "provider")
  // [requests failed by the injection, errors the provider's main task got,
  //  echo calls served].
  counts := rpc.invoke provider PROCEDURE-COUNT ["counts", 0]
  expect-equals thrown + 1 counts[0]
  expect counts[1] <= 1

/**
The request handler runs out of memory after it enqueued the request. The
  request is answered once: the procedure runs once and the caller gets the
  reply.
*/
test-request-after-enqueue provider/int -> none:
  counts := rpc.invoke provider PROCEDURE-COUNT ["counts", 0]
  thrown := counts[0]
  echoes := counts[2]
  rpc.invoke provider PROCEDURE-COUNT ["fail-after", 1]
  expect-equals "after" (call provider "after")
  // Gives a second, wrongly enqueued copy of the request time to run.
  sleep --ms=100
  counts = rpc.invoke provider PROCEDURE-COUNT ["counts", 0]
  expect-equals thrown + 1 counts[0]
  expect-equals echoes + 1 counts[2]

provider-main client/int -> none:
  broker := RpcBroker
  broker.install
  echoes := 0
  errors := 0
  requests/FailingHandler? := null
  stopped := false
  broker.register-procedure PROCEDURE-ECHO:: | args |
    echoes++
    args
  broker.register-procedure PROCEDURE-COUNT:: | args |
    if args[0] == "fail-before": requests.before = args[1]
    if args[0] == "fail-after": requests.after = args[1]
    if args[0] == "stop": stopped = true
    [requests.thrown, errors, echoes]
  requests = wrap SYSTEM-RPC-REQUEST_
  rpc.invoke client PROCEDURE-READY [Process.current.id]
  while not stopped:
    // The task that processes the messages here, gets the error of a
    // request handler that ran out of memory.
    exception := catch: sleep --ms=10
    if exception:
      expect-equals "OUT_OF_MEMORY" exception
      errors++
