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

import encoding.ubjson

class RpcBroker implements SystemMessageHandler_:
  procedures_/Map ::= {:}
  handlers_/Map ::= {:}
  queue_/RpcRequestQueue_ ::= RpcRequestQueue_

  on_message type gid pid message -> none:
    assert: type == SYSTEM_RPC_CHANNEL_LEGACY_
    decoded := ubjson.decode message
    id/int := decoded[0]
    name/int := decoded[1]

    send_exception_reply := (:| exception |
      process_send_bytes_ pid type (ubjson.encode [ id, true, exception ])
      return
    )

    procedures_.get name --if_present=: | procedure |
      if queue_.add (RpcRequest_ pid gid id decoded[2] procedure): return
      send_exception_reply.call "Cannot enqueue more requests"

    if decoded.is_empty:
      send_exception_reply.call "Missing call context"
    context ::= decoded[0]
    if context is not int:
      // TODO(kasper): This is a weird exception to pass back.
      send_exception_reply.call "Closed descriptor $context"

    handlers_.get name --if_present=: | handler |
      descriptor := get_descriptor_ gid context
      if not descriptor:
        send_exception_reply.call "Closed descriptor $context"
      request := RpcRequest_ pid gid id decoded[2]:: | arguments gid pid |
        handler.call descriptor arguments gid
      if queue_.add request: return
      send_exception_reply.call "Cannot enqueue more requests"

    send_exception_reply.call "No such procedure registered $name"

  // Register a regular procedure to handle a message.  The arguments to the
  // handler will be:
  //   arguments/List
  //   group_id/int
  //   process_id/int
  register_procedure name/int action/Lambda -> none:
    procedures_[name] = action

  // Register a descriptor-based procedure to handle a message.  These are
  // invoked by the RPC caller with a descriptor as the first argument.  This
  // descriptor is looked up on the process group and the resulting object is
  // passed to the handler.
  register_descriptor_procedure name/int action/Lambda:
    handlers_[name] = action

  // Typically overwritten in a subclass.
  get_descriptor_ gid/int descriptor/int -> any:
    return null

class RpcRequest_:
  next/RpcRequest_? := null

  pid/int
  gid/int
  id/int
  arguments/List
  procedure/Lambda

  constructor .pid .gid .id .arguments .procedure:

  process -> none:
    result/any := null
    try:
      result = procedure.call arguments gid pid
      if result is Serializable: result = result.serialize
    finally: | is_exception exception |
      reply := is_exception
          ? [ id, true, exception.value, exception.trace ]
          : [ id, false, result ]
      process_send_bytes_ pid SYSTEM_RPC_CHANNEL_LEGACY_ (ubjson.encode reply)
      return  // Stops any unwinding.

monitor RpcRequestQueue_:
  static MAX_TASKS ::= 2
  static MAX_REQUESTS ::= 8
  static IDLE_TIME_MS ::= 10_000

  first_/RpcRequest_? := null
  last_/RpcRequest_? := null

  size_/int := 0
  tasks_/int := 0

  add request/RpcRequest_ -> bool:
    if size_ >= MAX_REQUESTS: return false

    // Enqueue the new request in the linked list.
    last := last_
    if last:
      last.next = request
      last_ = request
    else:
      first_ = last_ = request
    size_++

    while size_ > tasks_ and tasks_ < MAX_TASKS:
      tasks_++
      task::
        // The task code runs outside the monitor, so the monitor
        // is unlocked when the requests are being processed but
        // locked when the requests are being dequeued.
        try:
          while next := remove_first: next.process
        finally:
          tasks_--
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
      size_--
      return request

// Serializable indicates a method can be serialized to a RPC-compatible value.
interface Serializable:
  // Must return a value that can be encoded to ubjson.
  serialize -> any
