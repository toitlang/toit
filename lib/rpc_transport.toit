// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import monitor
import uuid show Uuid
import binary show INT32_MAX

channel_resource_group_ ::= init_

/**
A bidirectional stream.
*/
class Stream_:
  static CLOSED_ERROR ::= "STREAM_CLOSED"

  streams_/Streams_? := ?
  channel_/Channel_ ::= ?
  id_/int ::= ?

  /**
  Constructs a stream with a fresh ID.

  # Advanced
  This constructor should be used by the client side where the ID is picked.
  */
  constructor .streams_ .channel_:
    id_ = streams_.open
    add_finalizer this::
      // TODO(Lau): How do we send this warning to the user?
      if streams_: print_ "WARNING: open stream $id_ was GC'ed."

  /**
  Constructs a stream using the given ID.

  # Advanced
  This constructor should be used by the server side where the ID needs to
    match an ID created by a client.
  */
  constructor.from_id .id_ .streams_ .channel_:
    streams_.open id_
    add_finalizer this::
      // TODO(Lau): How do we send this warning to the user?
      if streams_: print_ "WARNING: open stream $id_ was GC'ed."

  /**
  Closes the stream.

  The stream can be closed multiple times.
  */
  close -> none:
    if not streams_: return
    streams_.close id_
    streams_ = null

  receive -> Frame_:
    if not streams_: throw CLOSED_ERROR
    return streams_.receive id_

  send bits/int bytes/ByteArray:
    if not streams_: throw CLOSED_ERROR
    channel_.send id_ bits bytes

/**
Frame retrieved from channel.

Contains payload bytes and meta data.
*/
class Frame_:
  stream_id/int ::= ?
  bits/int ::= ?
  bytes/ByteArray ::= ?

  constructor .stream_id .bits .bytes:

/**
A stream demultiplexer. Demultiplexes messages received over a channel
  into their respective streams.
*/
class StreamDemux_:
  task_ := null
  channel_ ::= ?
  streams_ ::= ?

  constructor .channel_ .streams_:

  stop:
    if task_: task_.cancel
    task_ = null

  run:
    assert: not task_
    task_ = task --background:: run_

  /*
  Run loop for the demultiplexer.
  */
  run_:
    try:
      while true:
        frame := channel_.receive
        if frame:
          // Timeout if we spend more than 5s waiting to process an event.
          // It could indicate an fundamental issue in user code.
          with_timeout --ms=5000:
            streams_.dispatch frame
    finally:
      channel_.close

interface Dispatcher_:
  dispatch frame/Frame_ stream/Stream_

/**
Stream demultiplexer for servers.

Listens for new streams, dispatching them to appropriate handlers, and
  dispatching frames to the designated stream.
*/
class ServerStreamDemux_:
  channel_ ::= ?
  dispatcher/Dispatcher_ ::= ?
  streams_/Streams_ ::= ?
  task_ := null
  task_cache_ ::= monitor.TaskCache_

  constructor .channel_ .dispatcher .streams_:

  /**
  Starts the demux task.
  */
  run:
    assert: not task_
    task_ = task --background:: run_

  /**
  Stops the demux task.
  */
  stop:
    if task_: task_.cancel
    task_ = null

  run_:
    try:
      // Throws if the channel is closed in the other end.
      while true:
        frame := channel_.receive
        if not frame: continue
        if streams_.is_new_stream frame.stream_id:
          stream ::= Stream_.from_id frame.stream_id streams_ channel_
          task_cache_.run:: dispatcher.dispatch frame stream
        streams_.dispatch frame
    finally:
      channel_.close

/**
Monitor for keeping track of stream heads.

There is one of these per channel.

Streams are synchronized between client and server by having only the client
  create stream IDs.
The server discovers new streams by opening a stream for each ID the server
  hasn't seen before.
*/
// TODO(Lau): merge with coap's Sessions_ monitor.
monitor Streams_:
  // Maps stream IDs to head of streams. Contains null for open streams with
  // no pending frame.
  streams_ ::= {:} // map<int,Frame_>
  next_stream_id_ := 0

  take_next_stream_id_:
    return next_stream_id_++

  /**
  Opens stream.

  Returns the ID of the stream.

  # Advanced
  Must only be called by clients.
  */
  open -> int:
    id := take_next_stream_id_
    streams_.update id --if_absent=null: assert: false
    return id

  /**
  Opens a stream with the given $id.

  Returns the ID of the stream.

  # Advanced
  Must only be called by servers.
  */
  open id -> int:
    assert: id >= next_stream_id_
    next_stream_id_ = id + 1
    streams_.update id --if_absent=null: assert: false
    return id

  /**
  Checks whether $id is a new stream ID.
  */
  is_new_stream id -> bool:
    return id >= next_stream_id_

  /**
  Closes the stream identified by $id
  */
  close id/int:
    streams_.remove id

  /**
  Receives the head of stream $id.

  Blocks until a frame has been dispatched to the stream with ID $id.
  */
  receive id/int -> Frame_:
    response := null
    await: response = streams_.get id --if_absent=: throw "STREAM_CLOSED"
    if streams_.contains id:
      // Note: receiving from a stream does not close it. To close a stream
      // use `close`.
      streams_[id] = null
    return response

  /**
  Adds $frame to the stream with the stream ID in $frame.

  Blocks until the current head value of the stream has been taken.
  */
  dispatch frame/Frame_:
    // Wait for the pending frame to be processed.
    await: not streams_.get frame.stream_id
    streams_.update frame.stream_id --if_absent=(:return false): frame
    return true

/**
Channel for sending frames between processes.
*/
class Channel_:
  static DEFAULT_MAX_DELAY ::= Duration --s=2

  static READ_STATUS_ ::= 1
  static OPEN_STATUS_ ::= 2
  static WRITE_STATUS_ ::= 4
  static CLOSED_STATUS_ ::= 8

  static NO_SUCH_CHANNEL_ERROR ::= "NO_SUCH_CHANNEL_ERROR"
  static CHANNEL_CLOSED_ERROR ::= "CHANNEL_CLOSED_ERROR"

  state_/monitor.ResourceState_? := null
  streams_/Streams_? := null
  demux_/StreamDemux_? := null

  /**
  Creates one end of a channel.

  This operation blocks until the other end of the channel has been opened
    with $Channel_.open on $uuid.
  */
  constructor.create uuid/Uuid:
    id_bytes ::= uuid.to_byte_array
    peer ::= create_channel_ channel_resource_group_ id_bytes
    set_state_ peer
    system_send_bytes_ SYSTEM_RPC_CHANNEL_LEGACY_ id_bytes
    wait_for_open_status_

  /**
  Opens the other end of the channel identified by $uuid.
  */
  constructor.open uuid/Uuid:
    peer ::= open_channel_ channel_resource_group_ uuid.to_byte_array
    if not peer: throw NO_SUCH_CHANNEL_ERROR
    set_state_ peer
    send_status_ peer OPEN_STATUS_

  /**
  Works like $Channel_.create except that it doesn't block.

  Call $wait_for_open_status_ to block until the other end is open.
  */
  constructor.create_local uuid/Uuid:
    id_bytes := uuid.to_byte_array
    peer := create_channel_ channel_resource_group_ id_bytes
    set_state_ peer

  /**
  Waits for the open status produced by $Channel_.open.
  */
  wait_for_open_status_:
    try:
      with_timeout DEFAULT_MAX_DELAY:
        ensure_state_ OPEN_STATUS_
        clear_state_ OPEN_STATUS_
    finally: | is_exception _ |
      // TODO(Lau): Throw a more appropriate exception.
      if is_exception: close

  /**
  Creates a new stream.

  #Advanced
  If not started, this starts the background thread that consumes from this
    channel. Should not be used in combination with direct receives on the
    channel.
  */
  new_stream -> Stream_:
    ensure_streams_
    return Stream_ streams_ this

  ensure_streams_:
    if streams_: return
    streams_ = Streams_
    demux_ = StreamDemux_ this streams_
    demux_.run

  set_state_ peer:
    state_ = monitor.ResourceState_ channel_resource_group_ peer

  ensure_state_ state:
    ensure_state_
    return state_.wait_for_state state

  clear_state_ state:
    ensure_state_
    state_.clear_state state

  ensure_state_:
    // TODO(Lau): Figure out errors.
    if not state_: throw CHANNEL_CLOSED_ERROR

  handle_closed status:
    if status & CLOSED_STATUS_ == CLOSED_STATUS_:
      throw CHANNEL_CLOSED_ERROR

  /**
  Receives a frame from the channel.

  Blocks until a frame has been read.

  #Advanced
  Should not be used in combination with streams!
  */
  receive -> Frame_?:
    state := 0
    state = ensure_state_ READ_STATUS_ | CLOSED_STATUS_
    if not has_frame_ state_.resource:
      handle_closed state
      clear_state_ READ_STATUS_
      return null
    bytes ::= take_bytes_ state_.resource
    stream_id ::= get_stream_id_ state_.resource
    bits ::= get_bits_ state_.resource
    skip_ state_.resource
    return Frame_ stream_id bits bytes

  /**
  Sends a message frame to the other end of the channel.

  Throws $CHANNEL_CLOSED_ERROR if the other end of the channel has been
    closed.

  Blocks until the channel buffer has room for the message.
  */
  send stream_id bits/int bytes/ByteArray:
    write_message_ stream_id bits bytes

  write_message_ stream_id bits bytes:
    state := ensure_state_ WRITE_STATUS_ | CLOSED_STATUS_
    handle_closed state
    while not send_ state_.resource stream_id bits bytes:
      clear_state_ WRITE_STATUS_
      state = ensure_state_ WRITE_STATUS_ | CLOSED_STATUS_
      handle_closed state

  close:
    if not state_: return
    if demux_: demux_.stop
    close_ channel_resource_group_ state_.resource
    demux_ = null
    state_.dispose
    state_ = null


init_:
  #primitive.rpc.init

create_channel_ resource_group uuid:
  #primitive.rpc.create_channel

open_channel_ resource_group uuid:
  #primitive.rpc.open_channel

has_frame_ peer:
  #primitive.rpc.has_frame

get_stream_id_ peer:
  #primitive.rpc.get_stream_id

get_bits_ peer:
  #primitive.rpc.get_bits

take_bytes_ peer:
  #primitive.rpc.take_bytes

skip_ peer:
  #primitive.rpc.skip

send_ peer stream_id bits bytes:
  #primitive.rpc.send

send_status_ peer status:
  #primitive.rpc.send_status

close_ resource_group peer:
  #primitive.rpc.close
