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
  static MAX_TASKS/int    ::= 4
  static MAX_REQUESTS/int ::= 16

  procedures_/Map ::= {:}
  queue_/RpcRequestQueue_ ::= RpcRequestQueue_ MAX_TASKS

  install:
    set_system_message_handler_ SYSTEM_RPC_REQUEST_ this
    set_system_message_handler_ SYSTEM_RPC_CANCEL_ this

  /**
  Registers a procedure to handle a message.  The arguments to the
    handler will be:
  arguments/List
  group_id/int
  process_id/int
  */
  register_procedure name/int action/Lambda -> none:
    procedures_[name] = action

  // Unregister a procedure to handle a message.
  unregister_procedure name/int -> none:
    procedures_.remove name

  on_message type gid pid message/List -> none:
    id/int := message[0]
    if type == SYSTEM_RPC_CANCEL_:
      queue_.cancel pid id
      return

    assert: type == SYSTEM_RPC_REQUEST_
    name/int := message[1]
    arguments := message[2]

    send_exception_reply :=: | exception |
      process_send_ pid SYSTEM_RPC_REPLY_ [ id, true, exception, null ]
      return

    procedure := procedures_.get name
    if not procedure: send_exception_reply.call "No such procedure registered: $name"
    request := RpcRequest_ pid gid id arguments procedure
    if not queue_.add request: send_exception_reply.call "Cannot enqueue more requests"

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
      if result is RpcSerializable: result = result.serialize_for_rpc
    finally: | is_exception exception |
      reply := is_exception
          ? [ id, true, exception.value, exception.trace ]
          : [ id, false, result ]
      process_send_ pid SYSTEM_RPC_REPLY_ reply
      return  // Stops any unwinding.

monitor RpcRequestQueue_:
  static IDLE_TIME_MS ::= 1_000

  // We keep track of the current requests being processed in two parallel lists: One
  // containing the request being processed and one containing the processing task.
  // This allows the request and the associated task to be canceled if the client asks
  // for that.
  processing_requests_/List ::= ?
  processing_tasks_/List ::= ?

  first_/RpcRequest_? := null
  last_/RpcRequest_? := null

  unprocessed_/int := 0
  tasks_/int := 0

  constructor max_tasks/int:
    processing_requests_ = List max_tasks
    processing_tasks_ = List max_tasks

  add request/RpcRequest_ -> bool:
    if unprocessed_ >= RpcBroker.MAX_REQUESTS: return false

    // Enqueue the new request in the linked list.
    last := last_
    if last:
      last.next = request
      last_ = request
    else:
      first_ = last_ = request
    unprocessed_++

    ensure_processing_task_
    return true

  remove_first -> RpcRequest_?:
    while true:
      request := first_
      if not request:
        deadline := Time.monotonic_us + (IDLE_TIME_MS * 1_000)
        if not (try_await --deadline=deadline: first_ != null):
          return null
        continue

      // Dequeue the first request from the linked list.
      next := request.next
      if identical last_ request: last_ = next
      first_ = next
      return request

  cancel pid/int id/int -> int:
    // For testing purposes, we keep track of the number of requests that
    // were actually canceled through this operation.
    result/int := 0
    // First we get rid of any unprocessed request with the given id. This
    // is a simple linked list traversal with the usual bookkeeping challenges
    // that come from removing from a linked list with insertion at the end.
    previous := null
    current := first_
    while current:
      next := current.next
      if current.pid == pid and current.id == id:
        if previous:
          previous.next = next
        else:
          first_ = next
        if not next:
          last_ = previous
        unprocessed_--
        result++
      previous = current
      current = next
    // Then we cancel any requests that are in progress by canceling the
    // associated processing task.
    processing_requests_.size.repeat:
      request/RpcRequest_? := processing_requests_[it]
      if request and request.pid == pid and request.id == id:
        processing_tasks_[it].cancel
        result++
    return result

  ensure_processing_task_ -> none:
    // If there are requests that could be processed by spawning more tasks,
    // we do that now. To avoid spending too much memory on tasks, we prefer
    // to keep some requests unprocessed and enqueued.
    while unprocessed_ > tasks_ and tasks_ < processing_tasks_.size:
      tasks_++
      task_index := processing_tasks_.index_of null
      processing_tasks_[task_index] = task --background::
        // The task code runs outside the monitor, so the monitor
        // is unlocked when the requests are being processed but
        // locked when the requests are being dequeued.
        assert: identical processing_tasks_[task_index] task
        try:
          while not task.is_canceled:
            next := remove_first
            if not next: break
            try:
              processing_requests_[task_index] = next
              next.process
            finally:
              // This doesn't have to be in a finally-block because the call
              // to 'next.process' never unwinds, but being a little bit
              // defensive feels right.
              processing_requests_[task_index] = null
              unprocessed_--
        finally:
          processing_tasks_[task_index] = null
          tasks_--
          ensure_processing_task_
