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

  /** Fails outstanding calls to a process whose termination was observed. */
  peer-terminated pid/int -> none:
    synchronizer_.peer-terminated pid

  on-message type gid pid reply -> none:
    assert: type == SYSTEM-RPC-REPLY_
    if reply is not List or reply.size < 3 or reply[0] is not int: return
    id/int := reply[0]
    if not (synchronizer_.expects id pid): return
    if reply[1] is not bool: return
    is-exception/bool := reply[1]
    if is-exception and reply.size < 4: return
    result/any := reply[2]
    if is-exception: result = RpcException_ result reply[3]
    synchronizer_.receive id pid result

class RpcException_:
  exception/any
  trace/any
  constructor .exception .trace:

/** An outstanding call: the process it went to, and its result once known. */
class RpcCall_:
  pid/int
  result/any := RpcSynchronizer_.EMPTY

  constructor .pid:

monitor RpcSynchronizer_:
  static EMPTY ::= Object

  calls_/Map ::= {:}
  id_/int := 0

  send pid/int [send] -> any:
    id := id_
    id_ = id > 0x3fff_ffff ? 0 : id + 1

    // Negative destinations are aliases for the system process.
    // Replies carry its actual PID, not the alias used to submit the request.
    call := RpcCall_ (pid < 0 ? SYSTEM-PROCESS-ID_ : pid)
    calls := calls_
    try:
      calls[id] = call
      // Lock is kept during the non-blocking send.
      if send.call id pid:
        await: not identical EMPTY call.result
    finally: | is-exception exception |
      calls.remove id
      if is-exception:
        if exception.value == DEADLINE-EXCEEDED-ERROR or Task.current.is-canceled:
          process-send_ pid SYSTEM-RPC-CANCEL_ [ id ]

    result := call.result
    if result is not RpcException_:
      if not identical EMPTY result: return result
      throw "NO_SUCH_PROCESS"
    exception := result.exception
    if exception == CANCELED-ERROR: Task.current.cancel
    trace := result.trace
    if trace: rethrow exception trace
    throw exception

  peer-terminated pid/int -> none:
    calls_.do: | id/int call/RpcCall_ |
      if call.pid == pid and identical EMPTY call.result:
        call.result = RpcException_ "NO_SUCH_PROCESS" null

  expects id/int pid/int -> bool:
    call/RpcCall_? := calls_.get id
    return call != null and call.pid == pid

  receive id/int pid/int value/any -> none:
    call/RpcCall_? := calls_.get id
    if not call or call.pid != pid: return
    // Unless the existing value indicates that we are ready to receive
    // the result of the RPC call, we discard it.
    if identical EMPTY call.result: call.result = value

/**
Objects that are RPC-serializable can be serialized to a RPC-compatible
  value by calling their 'serialize_for_rpc' method.
*/
interface RpcSerializable:
  /// Must return a value that can be encoded using the built-in message encoder.
  serialize-for-rpc -> any
