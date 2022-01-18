// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

invoke name/int arguments/List -> any:
  return Rpc.instance.invoke name arguments

class Rpc implements SystemMessageHandler_:
  static instance ::= Rpc.internal_
  synchronizer_/RpcSynchronizer_ ::= RpcSynchronizer_

  constructor:
    return instance

  constructor.internal_:
    set_system_message_handler_ SYSTEM_RPC_MESSAGE_ this

  invoke name/int arguments/List -> any:
    return synchronizer_.send: | id |
      system_send_ SYSTEM_RPC_MESSAGE_ [ id, name, arguments ]

  on_message type gid pid reply -> none:
    assert: type == SYSTEM_RPC_MESSAGE_
    id/int := reply[0]
    is_exception/bool := reply[1]
    result/any := reply[2]
    if is_exception: result = RpcException_ result reply[3]
    synchronizer_.receive id result

class RpcException_:
  exception/any
  trace/any
  constructor .exception .trace:

monitor RpcSynchronizer_:
  static EMPTY ::= Object

  map_/Map ::= {:}
  id_/int := 0

  send [send] -> any:
    id := id_
    id_ = id > 0x3fff_ffff ? 0 : id + 1

    map := map_
    result/any := EMPTY
    try:
      map[id] = EMPTY
      send.call id  // Lock is kept during the non-blocking send.
      await:
        result = map[id]
        not identical EMPTY result
    finally:
      map.remove id

    if result is not RpcException_: return result

    exception := result.exception
    trace := result.trace
    if trace: rethrow exception trace
    throw exception

  receive id/int value/any -> none:
    map_.update id --if_absent=(: return): | existing |
      // Unless the existing value indicates that we are ready to receive
      // the result of the RPC call, we discard it.
      if not identical EMPTY existing: return
      value

/**
Has a close method suitable for objects that use a handle/descriptor
  to make RPC calls.
  The close method is designed to be robust.  It is called from a finalizer,
  can be called multiple times before that, and attempts to avoid failures
  during cancellation.
*/
abstract class CloseableProxy:
  handle_/int? := ?

  constructor .handle_:
    add_finalizer this:: this.close

  abstract close_rpc_selector_ -> int

  close:
    to_close := handle_
    if to_close:
      handle_ = null
      remove_finalizer this
      catch --trace:
        critical_do:
          invoke close_rpc_selector_ [to_close]
