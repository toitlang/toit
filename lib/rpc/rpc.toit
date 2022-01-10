// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import bytes
import encoding.ubjson
import encoding.protobuf
import monitor show Mutex Latch
import rpc_transport show Channel_ Stream_ Frame_
import uuid show uuid5

import .proto.rpc.rpc_pb

export *

RPC_PROTOBUF_ ::= 42

invoke procedure_name/int args/List -> any:
  return Rpc.instance.invoke procedure_name args

invoke request/Request -> Response:
  return Rpc.instance.invoke request

class Rpc:
  static instance ::= Rpc
  static channel_ := null

  // Bit 0-1.
  static HEADER_SIZE_ ::= 2
  static ERROR_MARKER_ ::= 0b1
  static BYTE_ARRAY_MARKER_ ::=0b10

  mutex ::= Mutex

  invoke procedure_name/int args/List -> any:
    ensure_channel_
    stream := channel_.new_stream
    try:
      args_bytes := ubjson.encode args
      header := frame_header_ procedure_name
      stream.send header args_bytes
      response := stream.receive
      return frame_data_ response
    finally:
      stream.close

  invoke request/Request -> Response:
    ensure_channel_
    stream := channel_.new_stream
    try:
      buffer := bytes.Buffer
      writer := protobuf.Writer buffer
      request.serialize writer
      bytes := buffer.bytes
      header := frame_header_ RPC_PROTOBUF_ --bytes
      stream.send header bytes
      response := stream.receive
      data/ByteArray := frame_data_ response
      reader := protobuf.Reader data
      return Response.deserialize reader
    finally:
      stream.close

  ensure_channel_:
    mutex.do: if not channel_: create_channel_

  create_channel_:
    stats ::= process_stats
    group_id := stats[5]
    process_id := stats[6]
    // TODO(Lau): Use UUID v4 (randomly rolled UUID) when available.
    id := uuid5 "$group_id, $process_id" "kernel channel"
    channel_ = Channel_.create id

  static frame_data_ frame/Frame_:
    if frame.bits & ERROR_MARKER_ == ERROR_MARKER_:
      args := ubjson.decode frame.bytes
      exception ::= args[0]
      trace ::= args[1]
      if trace: rethrow exception trace
      else: throw exception
    else if frame.bits & BYTE_ARRAY_MARKER_ == BYTE_ARRAY_MARKER_:
      return frame.bytes
    else:
      return ubjson.decode frame.bytes

  static frame_header_ procedure/int --error=false --bytes=false -> int:
    header := procedure << HEADER_SIZE_
    if error: header |= ERROR_MARKER_
    if bytes: header |= BYTE_ARRAY_MARKER_
    return header


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
