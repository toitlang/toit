// Copyright (C) 2021 Toitware ApS.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

import rpc show RpcSerializable

class RpcBroker implements SystemMessageHandler_ SystemMessageOutOfMemoryHandler_:
  static MAX-TASKS/int     ::= 16
  static MAX-REQUESTS/int? ::= 64
  // A single sandboxed (untrusted) process can't take up the whole request
  // queue, so it can't make the requests of every other client fail, nor
  // all processing tasks, so its slow requests can't hold up the requests
  // of every other client.
  static MAX-REQUESTS-PER-UNTRUSTED-PROCESS/int ::= MAX-TASKS / 2

  procedures_/Map ::= {:}
  queue_/RpcRequestQueue_ ::= RpcRequestQueue_ MAX-TASKS

  install:
    set-system-message-handler_ SYSTEM-RPC-REQUEST_ this
    set-system-message-handler_ SYSTEM-RPC-CANCEL_ this

  /**
  Determine if an incoming request from a given sender is accepted.

  This method is typically overridden in subclasses to filter out
  requests from unwanted senders.
  */
  accept gid/int pid/int -> bool:
    return true

  /**
  Registers a procedure to handle a message.  The arguments to the
    handler will be:
  - arguments/List
  - group-id/int
  - process-id/int
  */
  register-procedure name/int action/Lambda -> none:
    procedures_[name] = action

  // Unregister a procedure to handle a message.
  unregister-procedure name/int -> none:
    procedures_.remove name

  /**
  Cancels all requests associated with a given process id (pid).
  */
  cancel-requests pid/int -> none:
    queue_.cancel: | request/RpcRequest_ | request.pid == pid

  on-message type gid/int pid/int message/any -> none:
    // When canceling requests for specific processes, there can still be
    // enqueued system messages from such a process that will end up here.
    // To avoid having requests from such processes in the broker request
    // queue it is important to make 'accept' return false for them as part
    // of canceling their requests (do it before canceling to be sure).
    if not accept gid pid: return

    // Any process can send these messages. Drop malformed ones instead of
    // throwing: the handler runs in whatever task processes the messages.
    if message is not List or message.size < 1 or message[0] is not int: return
    id/int := message[0]
    if type == SYSTEM-RPC-CANCEL_:
      queue_.cancel: | request/RpcRequest_ | request.pid == pid and request.id == id
      return

    assert: type == SYSTEM-RPC-REQUEST_
    if message.size < 3 or message[1] is not int: return
    name/int := message[1]
    arguments := message[2]

    // The message processing hands a request whose handler ran out of
    // memory to this handler again (process-messages_). If the earlier
    // attempt ran out of memory after it enqueued the request, the request
    // will be processed and answered: it must not be enqueued twice.
    if is-retrying-rpc-message_ and queue_.was-last-added pid id: return

    procedure := procedures_.get name
    if not procedure:
      send-reply-now_ pid [ id, true, "No such procedure registered: $name", null ]
      return
    request := RpcRequest_ pid gid id arguments procedure --limited=(is-untrusted_ pid)
    if not queue_.add request:
      send-reply-now_ pid [ id, true, "Cannot enqueue more requests", null ]

  /**
  Completes the request of the $message from $pid whose $on-message ran out
    of memory: unless the request was enqueued before that (it will be
    answered), the client gets an OUT_OF_MEMORY error reply instead of
    waiting for a reply forever.

  Throws if this process can't allocate the message for the reply; the
    message processing then keeps the request and handles it again later.
  */
  on-out-of-memory type/int gid/int pid/int message/any -> none:
    if type != SYSTEM-RPC-REQUEST_: return
    if message is not List or message.size < 1 or message[0] is not int: return
    id/int := message[0]
    if queue_.was-last-added pid id: return
    send-out-of-memory-reply-now_ pid id

  // The reply to a request that this process can't accept or answer for
  // lack of memory. Allocated up front, so that sending it needs no object
  // allocation. Only the task that processes the messages uses it (one at
  // a time); the processing tasks build their own (send-reply_).
  out-of-memory-reply_/List ::= [0, true, "OUT_OF_MEMORY", null]

  /**
  Sends the out-of-memory error reply to the request $id of $pid without
    blocking.
  Throws if this process can't allocate the message: the caller then keeps
    the request to handle it again later.
  */
  send-out-of-memory-reply-now_ pid/int id/int -> none:
    reply := out-of-memory-reply_
    reply[0] = id
    exception := catch: process-send_ pid SYSTEM-RPC-REPLY_ reply
    // A full mailbox (a restricted sender only) or another error: dropped,
    // as send-reply-now_ does.
    if is-out-of-memory-error_ exception: throw "OUT_OF_MEMORY"

  // The policy kind of sandboxed processes (ContainerService.POLICY-UNTRUSTED).
  static POLICY-UNTRUSTED_ ::= 2
  // Whether this process may query the policy of other processes. Sandboxed
  // processes may not.
  static may-query-policy_/bool := true

  static is-untrusted_ pid/int -> bool:
    if not may-query-policy_ or pid == Process.current.id: return false
    kind := null
    exception := catch: kind = process-policy_ pid
    if exception:
      may-query-policy_ = false
      return false
    return kind == POLICY-UNTRUSTED_

  static process-policy_ pid/int -> int:
    #primitive.core.process-policy

  // Whether this process' messaging is restricted (it runs with the
  // untrusted policy). Only then can a send fail because the receiver's
  // mailbox is full: the VM drops other senders' messages to a full
  // mailbox instead.
  static restricted_/bool? := null

  static is-restricted_ -> bool:
    restricted := restricted_
    if restricted == null:
      kind := null
      // Sandboxed processes may not query policies, not even their own.
      exception := catch: kind = process-policy_ Process.current.id
      restricted = exception != null or kind == POLICY-UNTRUSTED_
      restricted_ = restricted
    return restricted

  // A restricted process' reply to a full mailbox is retried with an
  // exponential backoff (from 1 ms, at most 100 ms apart) for this long.
  static REPLY-RETRY-MS ::= 5_000
  static REPLY-RETRY-MAX-DELAY-MS ::= 100

  /**
  Sends the $reply to an RPC request to $pid.

  Never throws, so a reply that can't be delivered can't take down the
    task that sends it (or, through an uncaught exception, the process).
    Clients that make replies fail are clients that misbehave: they don't
    process their messages, or they ask for a reply that exceeds the
    quotas.

  If the reply can't be sent (it can't be serialized, exceeds this
    process' message size quota, or the receiver's mailbox is full), the
    request fails: a short exception reply with the error is sent
    instead, and if that can't be sent either, the reply is dropped.

  A process with restricted messaging gets `QUOTA_EXCEEDED` both for
    a reply that exceeds its quotas and for one that doesn't fit into the
    receiver's mailbox right now (which may be full of messages from
    other sandboxed senders). It retries the reply for $REPLY-RETRY-MS,
    unless the current task is canceled (the client canceled the request)
    or the receiver goes away, before it gives up.
  */
  static send-reply_ pid/int reply/List -> none:
    exception := catch: process-send_ pid SYSTEM-RPC-REPLY_ reply
    if not exception: return
    out-of-memory := is-out-of-memory-error_ exception
    if out-of-memory or (exception == "QUOTA_EXCEEDED" and is-restricted_):
      deadline := Time.monotonic-us + REPLY-RETRY-MS * 1_000
      delay-ms := 1
      while Time.monotonic-us < deadline:
        if Task.current.is-canceled: return
        if not pause_ delay-ms: return
        delay-ms = min REPLY-RETRY-MAX-DELAY-MS (delay-ms * 2)
        exception = catch: process-send_ pid SYSTEM-RPC-REPLY_ reply
        if not exception: return
        out-of-memory = is-out-of-memory-error_ exception
        if not out-of-memory and exception != "QUOTA_EXCEEDED": break
    if out-of-memory:
      send-out-of-memory-reply_ pid reply[0]
      return
    error := catch: send-reply-now_ pid [ reply[0], true, exception.stringify, null ]
    if error: send-out-of-memory-reply_ pid reply[0]

  /**
  Sends the $reply to an RPC request to $pid without blocking and drops
    it if it can't be sent, unless this process is out of memory.

  Throws if this process can't allocate the message.
  */
  static send-reply-now_ pid/int reply/List -> none:
    exception := catch: process-send_ pid SYSTEM-RPC-REPLY_ reply
    if is-out-of-memory-error_ exception: throw "OUT_OF_MEMORY"

  /**
  Waits $delay-ms between two attempts to send a reply. Returns false if the
    task was canceled.

  Yields instead when there is no memory for the timer of the sleep: the
    tasks that can free memory must get to run.
  */
  static pause_ delay-ms/int -> bool:
    exception := catch: sleep --ms=delay-ms
    if not exception: return true
    if not is-out-of-memory-error_ exception: return false
    catch: yield
    return not Task.current.is-canceled

  // The longest wait between two attempts of send-out-of-memory-reply_.
  static OUT-OF-MEMORY-RETRY-MAX-DELAY-MS ::= 1_000

  // How long a processing task tries to answer with an out-of-memory error
  // (send-out-of-memory-reply_) while this process is out of memory, before
  // it gives up.
  static OUT-OF-MEMORY-GIVE-UP-MS ::= 10_000

  /**
  Sends the out-of-memory error reply to the request $id of $pid from a
    processing task, when this process could not build or send the reply.

  Tries until the reply is sent, the client is gone (the send returns
    false), the request is canceled, the send fails for another reason
    than memory (a full mailbox, see $send-reply_), or for
    $OUT-OF-MEMORY-GIVE-UP-MS: the client must not wait for a reply that
    never comes. The attempts are at most
    $OUT-OF-MEMORY-RETRY-MAX-DELAY-MS apart; each one is a small, fixed
    amount of work. A client can't keep this going: it only runs while this
    process can't allocate a few bytes, and a sandboxed client's messages
    and heap are bounded by its quotas. The system process never gets here:
    it restarts the device when it is out of memory.
  */
  static send-out-of-memory-reply_ pid/int id/int -> none:
    delay-ms := 1
    deadline := Time.monotonic-us + OUT-OF-MEMORY-GIVE-UP-MS * 1_000
    while Time.monotonic-us < deadline:
      exception := catch:
        process-send_ pid SYSTEM-RPC-REPLY_ [ id, true, "OUT_OF_MEMORY", null ]
      if not exception or not is-out-of-memory-error_ exception: return
      if Task.current.is-canceled: return
      if not pause_ delay-ms: return
      delay-ms = min OUT-OF-MEMORY-RETRY-MAX-DELAY-MS (delay-ms * 2)

class RpcRequest_:
  next/RpcRequest_? := null

  pid/int
  gid/int
  id/int
  arguments/any
  procedure/Lambda
  // Whether the request counts towards the per-process limit of untrusted
  // senders.
  limited/bool

  constructor .pid .gid .id .arguments .procedure --.limited/bool=false:

  process -> none:
    result/any := null
    try:
      result = procedure.call arguments gid pid
      if result is RpcSerializable: result = result.serialize-for-rpc
    finally: | is-exception exception |
      // If we get an exception, we send back a string representation of
      // it to avoid running into issues with unserializable exceptions.
      reply/List? := null
      catch:
        reply = is-exception
            ? [ id, true, exception.value.stringify, exception.trace ]
            : [ id, false, result ]
      // Doesn't throw: a client that makes the reply fail can't take
      // down the processing task (and with it this process).
      if reply:
        RpcBroker.send-reply_ pid reply
      else:
        // Out of memory: the client gets the error instead of no reply.
        RpcBroker.send-out-of-memory-reply_ pid id
      return  // Stops any unwinding.

monitor RpcRequestQueue_:
  static IDLE-TIME-MS ::= 1_000

  // We keep track of the current requests being processed in two parallel lists: One
  // containing the request being processed and one containing the processing task.
  // This allows the request and the associated task to be canceled if the client asks
  // for that.
  processing-requests_/List ::= ?
  processing-tasks_/List ::= ?

  first_/RpcRequest_? := null
  last_/RpcRequest_? := null

  unprocessed_/int := 0
  tasks_/int := 0
  // The number of unprocessed requests (enqueued or being processed) of
  // each process that has any.
  unprocessed-by-pid_/Map ::= {:}  // Map<int, int>

  constructor max-tasks/int:
    processing-requests_ = List max-tasks
    processing-tasks_ = List max-tasks

  // The client and id of the request that was enqueued last (see
  // $was-last-added).
  last-added-pid_/int := -1
  last-added-id_/int := -1

  /**
  Whether the request that was enqueued last is the request $id of $pid.

  The broker asks after its handler ran out of memory, to know whether the
    request was enqueued before that (then it will be processed).
  */
  was-last-added pid/int id/int -> bool:
    return last-added-pid_ == pid and last-added-id_ == id

  /**
  Enqueues the $request and returns true, or returns false if the queue is
    full.

  If this process runs out of memory, the request either is not enqueued
    (then this method throws), or it is enqueued and $was-last-added says
    so. An enqueued request always has a processing task: when none runs,
    one is started before the request is enqueued.
  */
  add request/RpcRequest_ -> bool:
    pid := request.pid
    id := request.id
    limited := request.limited
    if unprocessed_ >= RpcBroker.MAX-REQUESTS
        or (limited and
            (unprocessed-by-pid_.get pid --if-absent=: 0) >= RpcBroker.MAX-REQUESTS-PER-UNTRUSTED-PROCESS):
      // It should not be necessary to ask for more processing tasks here,
      // but we do it (defensively) anyway to guard against issues in the
      // bookkeeping of unprocessed requests and processing tasks.
      ensure-processing-task_
      return false

    // The processing tasks end when they are idle. Without one, a request
    // that is enqueued when no task can be started would stay in the queue
    // until the next request comes.
    if tasks_ == 0: ensure-processing-task_ --at-least-one

    // Enqueue the new request in the linked list. The enqueued request is
    // recorded right after it is linked in, with no call in between.
    last := last_
    if last:
      last.next = request
      last_ = request
    else:
      first_ = last_ = request
    unprocessed_++
    last-added-pid_ = pid
    last-added-id_ = id

    // Running out of memory from here on leaves the request enqueued: the
    // count of a sandboxed sender is then one too low until the request has
    // been processed (decrement_ handles that), and the tasks that run
    // process the queue.
    catch --unwind=(: not is-out-of-memory-error_ it):
      if limited: unprocessed-by-pid_.update pid --init=0: it + 1
      ensure-processing-task_
    return true

  // Static, so it doesn't take the monitor lock: it is called both with and
  // without the lock held.
  static decrement_ unprocessed-by-pid/Map request/RpcRequest_ -> none:
    if not request.limited: return
    pid := request.pid
    count := unprocessed-by-pid.get pid --if-absent=: 0
    if count <= 1:
      unprocessed-by-pid.remove pid
    else:
      unprocessed-by-pid[pid] = count - 1

  remove-first task-index/int -> RpcRequest_?:
    while true:
      request := first_
      if not request:
        deadline := Time.monotonic-us + (IDLE-TIME-MS * 1_000)
        if not (try-await --deadline=deadline: first_ != null):
          return null
        continue

      // Mark the request as being processed by the task with the
      // given index while still holding the monitor lock. This
      // ensures that the returned request can be canceled even
      // though it isn't in the linked list anymore. Done before the
      // request is dequeued, with the calls: if this process runs out of
      // memory here, the request is still in the queue or marked.
      next := request.next
      processing-requests_[task-index] = request

      // Dequeue the first request from the linked list.
      if identical last_ request: last_ = next
      first_ = next
      return request

  cancel [predicate] -> none:
    // First we get rid of any unprocessed request where the 'predicate' block
    // answers true. This is a simple linked list traversal with the usual
    // bookkeeping challenges that come from removing from a linked list with
    // insertion at the end.
    previous := null
    current := first_
    while current:
      next := current.next
      if predicate.call current:
        if previous:
          previous.next = next
        else:
          first_ = next
        if not next:
          last_ = previous
        unprocessed_--
        decrement_ unprocessed-by-pid_ current
      else:
        previous = current
      current = next
    // Then we cancel any requests that are in progress by canceling the
    // associated processing task.
    processing-requests_.size.repeat:
      request/RpcRequest_? := processing-requests_[it]
      if request and predicate.call request:
        processing-tasks_[it].cancel

  ensure-processing-task_ --at-least-one/bool=false -> none:
    // If there are requests that could be processed by spawning more tasks,
    // we do that now. To avoid spending too much memory on tasks, we prefer
    // to keep some requests unprocessed and enqueued.
    // A task is only counted once it exists: a task that can't be created
    // for lack of memory must not count as processing the queue.
    while (unprocessed_ > tasks_ or (at-least-one and tasks_ == 0))
        and tasks_ < processing-tasks_.size:
      task-index := processing-tasks_.index-of null
      processing-tasks_[task-index] = task --name="RPC processing task" --background::
        // The task code runs outside the monitor, so the monitor
        // is unlocked when the requests are being processed but
        // locked when the requests are being dequeued.
        assert: identical processing-tasks_[task-index] Task.current
        try:
          while not Task.current.is-canceled:
            next/RpcRequest_? := null
            exception := catch --unwind=(: not is-out-of-memory-error_ it):
              next = remove-first task-index
            if exception:
              // Out of memory (it could not grow its stack, or it got the
              // error of the message processing). A request that it
              // marked before that is still processed. Otherwise it lets
              // the other tasks run, which may free memory, and tries again.
              // If it can't even yield (it can't grow its stack for the
              // call), no other task gets to run and free memory: the error
              // ends the task, and with it the process, as it did before.
              next = processing-requests_[task-index]
              if not next:
                stuck := catch: yield
                if stuck: throw exception
                continue
            if not next: break
            try:
              // Doesn't unwind, except when this process runs out of
              // memory before it could start to answer: the request is
              // then failed with that error (an uncaught exception would
              // end this process).
              failed := catch --unwind=(: not is-out-of-memory-error_ it):
                next.process
              if failed: RpcBroker.send-out-of-memory-reply_ next.pid next.id
            finally:
              // This doesn't have to be in a finally-block because the call
              // to 'next.process' never unwinds, but being a little bit
              // defensive feels right.
              processing-requests_[task-index] = null
              unprocessed_--
              decrement_ unprocessed-by-pid_ next
        finally:
          processing-tasks_[task-index] = null
          tasks_--
          // Out of memory: the tasks that run (or the next request) take
          // over; an exception would end this process.
          catch --unwind=(: not is-out-of-memory-error_ it):
            ensure-processing-task_
      tasks_++
