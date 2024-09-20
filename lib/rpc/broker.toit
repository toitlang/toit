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

class RpcBroker implements SystemMessageHandler_:
  static MAX-TASKS/int     ::= 16
  static MAX-REQUESTS/int? ::= 64

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

  on-message type gid/int pid/int message/List -> none:
    // When canceling requests for specific processes, there can still be
    // enqueued system messages from such a process that will end up here.
    // To avoid having requests from such processes in the broker request
    // queue it is important to make 'accept' return false for them as part
    // of canceling their requests (do it before canceling to be sure).
    if not accept gid pid: return

    id/int := message[0]
    if type == SYSTEM-RPC-CANCEL_:
      queue_.cancel: | request/RpcRequest_ | request.pid == pid and request.id == id
      return

    assert: type == SYSTEM-RPC-REQUEST_
    name/int := message[1]
    arguments := message[2]

    send-exception-reply :=: | exception |
      process-send_ pid SYSTEM-RPC-REPLY_ [ id, true, exception, null ]
      return

    procedure := procedures_.get name
    if not procedure: send-exception-reply.call "No such procedure registered: $name"
    request := RpcRequest_ pid gid id arguments procedure
    if not queue_.add request: send-exception-reply.call "Cannot enqueue more requests"

class RpcRequest_:
  next/RpcRequest_? := null

  pid/int
  gid/int
  id/int
  arguments/any
  procedure/Lambda

  constructor .pid .gid .id .arguments .procedure:

  process -> none:
    result/any := null
    try:
      result = procedure.call arguments gid pid
      if result is RpcSerializable: result = result.serialize-for-rpc
    finally: | is-exception exception |
      // If we get an exception, we send back a string representation of
      // it to avoid running into issues with unserializable exceptions.
      reply := is-exception
          ? [ id, true, exception.value.stringify, exception.trace ]
          : [ id, false, result ]
      process-send_ pid SYSTEM-RPC-REPLY_ reply
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

  constructor max-tasks/int:
    processing-requests_ = List max-tasks
    processing-tasks_ = List max-tasks

  add request/RpcRequest_ -> bool:
    if unprocessed_ >= RpcBroker.MAX-REQUESTS:
      // It should not be necessary to ask for more processing tasks here,
      // but we do it (defensively) anyway to guard against issues in the
      // bookkeeping of unprocessed requests and processing tasks.
      ensure-processing-task_
      return false

    // Enqueue the new request in the linked list.
    last := last_
    if last:
      last.next = request
      last_ = request
    else:
      first_ = last_ = request
    unprocessed_++

    ensure-processing-task_
    return true

  remove-first task-index/int -> RpcRequest_?:
    while true:
      request := first_
      if not request:
        deadline := Time.monotonic-us + (IDLE-TIME-MS * 1_000)
        if not (try-await --deadline=deadline: first_ != null):
          return null
        continue

      // Dequeue the first request from the linked list.
      next := request.next
      if identical last_ request: last_ = next
      first_ = next

      // Mark the request as being processed by the task with the
      // given index while still holding the monitor lock. This
      // ensures that the returned request can be canceled even
      // though it isn't in the linked list anymore.
      processing-requests_[task-index] = request
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
      else:
        previous = current
      current = next
    // Then we cancel any requests that are in progress by canceling the
    // associated processing task.
    processing-requests_.size.repeat:
      request/RpcRequest_? := processing-requests_[it]
      if request and predicate.call request:
        processing-tasks_[it].cancel

  ensure-processing-task_ -> none:
    // If there are requests that could be processed by spawning more tasks,
    // we do that now. To avoid spending too much memory on tasks, we prefer
    // to keep some requests unprocessed and enqueued.
    while unprocessed_ > tasks_ and tasks_ < processing-tasks_.size:
      tasks_++
      task-index := processing-tasks_.index-of null
      processing-tasks_[task-index] = task --name="RPC processing task" --background::
        // The task code runs outside the monitor, so the monitor
        // is unlocked when the requests are being processed but
        // locked when the requests are being dequeued.
        assert: identical processing-tasks_[task-index] Task.current
        try:
          while not Task.current.is-canceled:
            next := remove-first task-index
            if not next: break
            try:
              next.process
            finally:
              // This doesn't have to be in a finally-block because the call
              // to 'next.process' never unwinds, but being a little bit
              // defensive feels right.
              processing-requests_[task-index] = null
              unprocessed_--
        finally:
          processing-tasks_[task-index] = null
          tasks_--
          ensure-processing-task_
