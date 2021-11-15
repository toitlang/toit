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

import encoding.ubjson as ubjson
import monitor
import rpc_transport show Channel_ Frame_
import uuid show Uuid
import rpc

export *

class RpcBroker implements SystemMessageHandler_:
  task_cache_/monitor.TaskCache_
  handlers_ ::= {:}
  named_handlers_ ::= {:}
  descriptor_handlers_ ::= {:}
  tpack_handlers_ ::= {:}

  constructor .task_cache_:

  register_procedure --tpack procedure/int handler/Lambda:
    tpack_handlers_[procedure] = handler

  // Register a regular procedure to handle a message.  The arguments to the
  // handler will be:
  //   process_manager/ProcessManager
  //   arguments/List
  //   group_id/int
  //   process_id/int
  register_procedure procedure_name/int handler/Lambda:
    handlers_[procedure_name] = handler

  // Register a regular procedure to handle a message, matching a name.
  // The third argument must be the name.
  register_named_procedure name/string procedure_name/int handler/Lambda:
    map := named_handlers_.get procedure_name --init=:{:}
    map[name] = handler

  // Register a descriptor-based procedure to handle a message.  These are
  // invoked by the RPC caller with a descriptor as the first argument.  This
  // descriptor is looked up on the process group and the resulting object is
  // passed to the handler.
  register_descriptor_procedure procedure_name/int handler/Lambda:
    descriptor_handlers_[procedure_name] = handler

  get_descriptor_ gid context:
    return null

  get_handler_ gid procedure_name procedure_args [--on_error]:
    handlers_.get procedure_name --if_present=: return it

    if procedure_args.size == 0:
      on_error.call "Missing call context"
      return null

    context ::= procedure_args[0]

    named_handlers_.get procedure_name --if_present=:
      it.get context --if_present=: return it

    // The descriptor must be an integer.
    if context is not int:
      on_error.call "Closed descriptor $context"
      return null

    descriptor_handlers_.get procedure_name --if_present=: | handler |
      driver := get_descriptor_ gid context
      if driver: return :: | args gid pid |
        handler.call driver args gid

      on_error.call "Closed descriptor $context"
      return null

    on_error.call "No such procedure registered $procedure_name"
    return null

  on_message type gid pid args:
    if type == SYSTEM_RPC_CHANNEL_LEGACY_:
      on_open_channel_ gid pid args
      return

  static is_rpc_error_ error -> bool:
    if error == Channel_.CHANNEL_CLOSED_ERROR: return true
    if error == Channel_.NO_SUCH_CHANNEL_ERROR: return true
    return false

  on_open_channel_ gid pid id_bytes:
    task::
      catch --trace=(: not is_rpc_error_ it):
        channel := Channel_.open (Uuid id_bytes)
        try:
          listen_ gid pid channel
        finally:
          channel.close

  listen_ gid pid channel/Channel_:
    while true:
      frame := channel.receive
      if not frame: continue

      procedure_name := frame.bits >> rpc.Rpc.HEADER_SIZE_
      procedure_args := rpc.Rpc.frame_data_ frame
      handler := get_handler_ gid procedure_name procedure_args --on_error=: | err | report_error channel frame.stream_id err null
      if not handler: continue
      task_cache_.run:: process_handler channel frame handler procedure_args gid pid

  process_handler channel/Channel_ frame/Frame_ handler procedure_args gid pid:
    catch --trace=(: not is_rpc_error_ it):
      try:
        result := handler.call procedure_args gid pid
        if result is Serializable: result = result.serialize
        is_bytes := result is ByteArray
        if not is_bytes: result = ubjson.encode result
        channel.send
          frame.stream_id
          rpc.Rpc.frame_header_ 0 --bytes=is_bytes
          result
      finally: | is_exception exception |
        if is_exception:
          report_error channel frame.stream_id exception.value exception.trace

  report_error channel/Channel_ stream_id/int exception trace -> bool:
    // Throws if the channel is closed in the other end.
    catch --trace=(: not is_rpc_error_ it):
      channel.send
        stream_id
        rpc.Rpc.frame_header_ 0 --error
        ubjson.encode [exception, trace]
    return true

// Serializable indicates a method can be serialized to a RPC-compatible value.
interface Serializable:
  serialize -> any
