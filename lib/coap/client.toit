// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import log
import monitor
import bytes

import .transport
import .message
import .option

CLOSED_ERROR ::= "TRANSPORT_CLOSED"
SESSION_CLOSED_ERROR ::= "SESSION_CLOSED_ERROR"

/**
CoAP client to talk with a CoAP endpoint. The client is initiated with
  the underlying platform-specific transport, e.g. StreamTransport.
*/
class Client:
  static DEFAULT_MAX_DELAY ::= Duration --s=10

  max_progress_delay/Duration ::= ?

  transport_/Transport ::= ?
  sessions_ ::= Sessions_
  write_lock_ ::= monitor.Mutex
  logger_ ::= (log.default.with_name "coap").with_level log.INFO_LEVEL

  closed_ := false

  run_task_ := null

  constructor .transport_ --auto_run=true --.max_progress_delay=DEFAULT_MAX_DELAY:
    // Run the client task, processing incoming data.
    if auto_run:
      run_task_ = task::
        e := catch: run
        if e and e != CLOSED_ERROR:
          logger_.error "error processing transport" --tags={"error": e}
        run_task_ = null

  // Returns true if the underlying transport is reliable, meaning no
  // messages are lost and are delivered in order.
  reliable -> bool:
    return transport_.reliable

  // Close the client. It's okay to call close multiple times.
  close:
    closed_ = true  // Mark closed before delivering closed error to other clients.
    sessions_.abort CLOSED_ERROR
    transport_.close
    if run_task_: run_task_.cancel

  is_closed -> bool: return closed_

  new_message --reliable=true -> Message:
    msg := transport_.new_message --reliable=reliable
    return msg

  unary msg/Message --token_id=null -> Message:
    logger_.debug "sending unary request" --tags={"path": msg.path}
    stream_ msg --token_id=token_id:
      logger_.debug "unary response" --tags={"path": msg.path}
      return it
    throw "CLIENT_ERROR"

  stream msg/Message --token_id=null [on_message]:
    logger_.debug "sending stream request" --tags={"path": msg.path}
    stream_ msg --token_id=token_id:
      logger_.debug "stream response" --tags={"path": msg.path}
      on_message.call it
    logger_.debug "stream ended" --tags={"path": msg.path}

  stream_start --token_id=null -> Token:
    logger_.debug "creating stream token"
    token := token_id ? Token token_id : Token.create_random
    sessions_.enter token
    return token

  stream_read token/Token --use_max_progress_delay=true -> Message:
    msg := read_response_ token --use_max_progress_delay=use_max_progress_delay
    logger_.debug "stream response"
    return msg

  stream_end token/Token -> none:
    logger_.debug "stream ended"
    sessions_.leave token

  oneway msg/Message -> none:
    logger_.debug "sending oneway request" --tags={"path": msg.path}
    send_ msg

  get path --token_id=null -> Message:
    msg := transport_.new_message
    msg.code = CODE_GET
    msg.add_path path
    return unary --token_id=token_id msg

  post path payload/ByteArray --token_id=null -> Message:
    msg := transport_.new_message
    msg.code = CODE_POST
    msg.add_path path
    msg.payload = bytes.Reader payload
    return unary --token_id=token_id msg

  put path payload/ByteArray --token_id=null -> Message:
    msg := transport_.new_message
    msg.code = CODE_PUT
    msg.add_path path
    msg.payload = bytes.Reader payload
    return unary --token_id=token_id msg

  max_suggested_payload_size -> int:
    // Remove 32 bytes for header and options. In practice, we often
    // see the overhead being exactly 30 bytes, so this is a conservative
    // estimate.
    return transport_.mtu - 32

  observe path --token_id=null [on_message]:
    observing := 0
    unsubscribe := false
    try:
      msg := transport_.new_message
      msg.code = CODE_GET
      msg.options.add
        Option.uint OPTION_OBSERVE 0
      msg.add_path path
      stream_ --token_id=token_id msg --no-use_max_progress_delay: | reply |
        num := reply.options.reduce --initial=-1: | v o | o.number == OPTION_OBSERVE ? o.as_uint : v
        unsubscribe = true
        // TODO: This is too strict by the spec.
        if num != observing: throw "OBSERVE_FAILED"
        observing++
        on_message.call reply
        unsubscribe = false
    finally:
      // Unsubscribe when done.
      if unsubscribe and observing > 0:
        msg := transport_.new_message
        msg.code = CODE_GET
        msg.options.add
          Option.uint OPTION_OBSERVE 1
        msg.add_path path
        unary --token_id=token_id msg

  on_read_write_error_ error:
    // Always close the CoAP client, but allow timeout errors
    // to pass through to the caller. All other errors are
    // mapped to CLOSED_ERROR.
    close
    if error == DEADLINE_EXCEEDED_ERROR:
      return true  // Continue unwinding with original error.
    else:
      throw CLOSED_ERROR

  stream_ msg/Message --token_id=null --use_max_progress_delay=true [on_message]:
    token := stream_start --token_id=token_id
    msg.token = token
    try:
      send_ msg
      while true:
        reply := read_response_ token --use_max_progress_delay=use_max_progress_delay
        on_message.call reply
    finally:
      stream_end token

  read_response_ token/Token --use_max_progress_delay=true -> Message:
    // If enabled, cap the delay between each response.
    response := null
    catch --unwind=(: on_read_write_error_ it):
      with_timeout (use_max_progress_delay ? max_progress_delay : null):
        response = sessions_.get_response token
    if response.error: throw response.error
    reply := response.message
    if reply.code_class != CODE_CLASS_SUCCESS:
      throw "COAP ERROR $reply.code: $reply.read_payload.to_string_non_throwing"
    return reply

  send_ msg/Message:
    if closed_: throw CLOSED_ERROR
    if msg.code_class != CODE_CLASS_REQUEST: throw "FORMAT_ERROR"
    // Always use max_progress_delay for writing to transport.
    catch --unwind=(: on_read_write_error_ it):
      with_timeout max_progress_delay:
        write_lock_.do: transport_.write msg

  run -> none:
    try:
      while true:
        response := transport_.read
        // Stop if transport was closed.
        if not response:
          logger_.debug "underlying transport closed the connection"
          return
        if not sessions_.dispatch_response response:
          while response.message.payload.read:
          logger_.warn "unpaired response"
    finally:
      close

monitor Sessions_:
  sessions_ ::= {:}

  sequence_number_ := 0

  enter token:
    sessions_.update token --if_absent=null: throw "INVALID_TOKEN"

  leave token:
    sessions_.remove token

  get_response token:
    response := null
    await: response = sessions_.get token --if_absent=: Response.error null SESSION_CLOSED_ERROR
    if sessions_.contains token: sessions_[token] = null
    return response

  dispatch_response response:
    // Wait for the current message to be processed.
    await: not sessions_.get response.token
    sequence_number_++
    sessions_.update response.token --if_absent=(:return false): response
    return true

  abort error:
    // Terminate non-completed sessions with an closed error.
    sessions_.map --in_place: | token response |
      response ? response : Response.error null error
