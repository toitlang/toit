// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import monitor

invoke name/int arguments/any --sequential/bool=false -> any:
  return Rpc.instance.invoke -1 name arguments --sequential=sequential

invoke pid/int name/int arguments/any --sequential/bool=false -> any:
  return Rpc.instance.invoke pid name arguments --sequential=sequential

class Rpc implements SystemMessageHandler_:
  static instance ::= Rpc.internal_
  synchronizer_/RpcSynchronizer_ ::= RpcSynchronizer_

  // Sometimes it is useful to be able to force requests from various tasks
  // to be sent in sequence rather than concurrently. We use a mutex for this.
  sequencer_/monitor.Mutex ::= monitor.Mutex

  constructor:
    return instance

  constructor.internal_:
    set-system-message-handler_ SYSTEM-RPC-REPLY_ this

  invoke pid/int name/int arguments/any --sequential/bool -> any:
    if arguments is RpcSerializable: arguments = arguments.serialize-for-rpc
    send ::= :
      synchronizer_.send pid: | id pid |
        process-send_ pid SYSTEM-RPC-REQUEST_ [ id, name, arguments ]
    return sequential ? (sequencer_.do send) : send.call

  on-message type gid pid reply -> none:
    assert: type == SYSTEM-RPC-REPLY_
    id/int := reply[0]
    is-exception/bool := reply[1]
    result/any := reply[2]
    if is-exception: result = RpcException_ result reply[3]
    synchronizer_.receive id result

class RpcException_:
  exception/any
  trace/any
  constructor .exception .trace:

monitor RpcSynchronizer_:
  static EMPTY ::= Object

  map_/Map ::= {:}
  id_/int := 0

  send pid/int [send] -> any:
    id := id_
    id_ = id > 0x3fff_ffff ? 0 : id + 1

    map := map_
    result/any := EMPTY
    try:
      map[id] = EMPTY
      // Lock is kept during the non-blocking send.
      if send.call id pid:
        await:
          result = map[id]
          not identical EMPTY result
    finally: | is-exception exception |
      map.remove id
      if is-exception:
        if exception.value == DEADLINE-EXCEEDED-ERROR or Task.current.is-canceled:
          process-send_ pid SYSTEM-RPC-CANCEL_ [ id ]

    if result is not RpcException_:
      if not identical EMPTY result: return result
      throw "NO_SUCH_PROCESS"
    exception := result.exception
    if exception == CANCELED-ERROR: Task.current.cancel
    trace := result.trace
    if trace: rethrow exception trace
    throw exception

  receive id/int value/any -> none:
    map_.update id --if-absent=(: return): | existing |
      // Unless the existing value indicates that we are ready to receive
      // the result of the RPC call, we discard it.
      if not identical EMPTY existing: return
      value

/**
Objects that are RPC-serializable can be serialized to a RPC-compatible
  value by calling their 'serialize_for_rpc' method.
*/
interface RpcSerializable:
  /// Must return a value that can be encoded using the built-in message encoder.
  serialize-for-rpc -> any
