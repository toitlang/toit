// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io
import log
import monitor

import .transport
import .message
import .option

CLOSED-ERROR ::= "TRANSPORT_CLOSED"
SESSION-CLOSED-ERROR ::= "SESSION_CLOSED_ERROR"

/**
CoAP client to talk with a CoAP endpoint. The client is initiated with
  the underlying platform-specific transport, e.g. StreamTransport.
*/
class Client:
  static DEFAULT-MAX-DELAY ::= Duration --s=10

  max-progress-delay/Duration ::= ?

  transport_/Transport ::= ?
  sessions_ ::= Sessions_
  write-lock_ ::= monitor.Mutex
  logger_ ::= (log.default.with-name "coap").with-level log.INFO-LEVEL

  closed_ := false

  run-task_ := null

  constructor .transport_ --auto-run=true --.max-progress-delay=DEFAULT-MAX-DELAY:
    // Run the client task, processing incoming data.
    if auto-run:
      run-task_ = task::
        e := catch: run
        if e and e != CLOSED-ERROR:
          logger_.error "error processing transport" --tags={"error": e}
        run-task_ = null

  // Returns true if the underlying transport is reliable, meaning no
  // messages are lost and are delivered in order.
  reliable -> bool:
    return transport_.reliable

  // Close the client. It's okay to call close multiple times.
  close:
    closed_ = true  // Mark closed before delivering closed error to other clients.
    sessions_.abort CLOSED-ERROR
    transport_.close
    if run-task_: run-task_.cancel

  is-closed -> bool: return closed_

  new-message --reliable=true -> Message:
    msg := transport_.new-message --reliable=reliable
    return msg

  unary msg/Message --token-id=null -> Message:
    logger_.debug "sending unary request" --tags={"path": msg.path}
    stream_ msg --token-id=token-id:
      logger_.debug "unary response" --tags={"path": msg.path}
      return it
    throw "CLIENT_ERROR"

  stream msg/Message --token-id=null [on-message]:
    logger_.debug "sending stream request" --tags={"path": msg.path}
    stream_ msg --token-id=token-id:
      logger_.debug "stream response" --tags={"path": msg.path}
      on-message.call it
    logger_.debug "stream ended" --tags={"path": msg.path}

  stream-start --token-id=null -> Token:
    logger_.debug "creating stream token"
    token := token-id ? Token token-id : Token.create-random
    sessions_.enter token
    return token

  stream-read token/Token --use-max-progress-delay=true -> Message:
    msg := read-response_ token --use-max-progress-delay=use-max-progress-delay
    logger_.debug "stream response"
    return msg

  stream-end token/Token -> none:
    logger_.debug "stream ended"
    sessions_.leave token

  oneway msg/Message -> none:
    logger_.debug "sending oneway request" --tags={"path": msg.path}
    send_ msg

  get path --token-id=null -> Message:
    msg := transport_.new-message
    msg.code = CODE-GET
    msg.add-path path
    return unary --token-id=token-id msg

  post path payload/ByteArray --token-id=null -> Message:
    msg := transport_.new-message
    msg.code = CODE-POST
    msg.add-path path
    msg.payload = io.Reader payload
    return unary --token-id=token-id msg

  put path payload/ByteArray --token-id=null -> Message:
    msg := transport_.new-message
    msg.code = CODE-PUT
    msg.add-path path
    msg.payload = io.Reader payload
    return unary --token-id=token-id msg

  max-suggested-payload-size -> int:
    // Remove 32 bytes for header and options. In practice, we often
    // see the overhead being exactly 30 bytes, so this is a conservative
    // estimate.
    return transport_.mtu - 32

  observe path --token-id=null [on-message]:
    observing := 0
    unsubscribe := false
    try:
      msg := transport_.new-message
      msg.code = CODE-GET
      msg.options.add
        Option.uint OPTION-OBSERVE 0
      msg.add-path path
      stream_ --token-id=token-id msg --no-use-max-progress-delay: | reply |
        num := reply.options.reduce --initial=-1: | v o | o.number == OPTION-OBSERVE ? o.as-uint : v
        unsubscribe = true
        // TODO: This is too strict by the spec.
        if num != observing: throw "OBSERVE_FAILED"
        observing++
        on-message.call reply
        unsubscribe = false
    finally:
      // Unsubscribe when done.
      if unsubscribe and observing > 0:
        msg := transport_.new-message
        msg.code = CODE-GET
        msg.options.add
          Option.uint OPTION-OBSERVE 1
        msg.add-path path
        unary --token-id=token-id msg

  on-read-write-error_ error:
    // Always close the CoAP client, but allow timeout errors
    // to pass through to the caller. All other errors are
    // mapped to CLOSED-ERROR.
    close
    if error == DEADLINE-EXCEEDED-ERROR:
      return true  // Continue unwinding with original error.
    else:
      throw CLOSED-ERROR

  stream_ msg/Message --token-id=null --use-max-progress-delay=true [on-message]:
    token := stream-start --token-id=token-id
    msg.token = token
    try:
      send_ msg
      while true:
        reply := read-response_ token --use-max-progress-delay=use-max-progress-delay
        on-message.call reply
    finally:
      stream-end token

  read-response_ token/Token --use-max-progress-delay=true -> Message:
    // If enabled, cap the delay between each response.
    response := null
    catch --unwind=(: on-read-write-error_ it):
      with-timeout (use-max-progress-delay ? max-progress-delay : null):
        response = sessions_.get-response token
    if response.error: throw response.error
    reply := response.message
    if reply.code-class != CODE-CLASS-SUCCESS:
      throw "COAP ERROR $reply.code: $reply.read-payload.to-string-non-throwing"
    return reply

  send_ msg/Message:
    if closed_: throw CLOSED-ERROR
    if msg.code-class != CODE-CLASS-REQUEST: throw "FORMAT_ERROR"
    // Always use max-progress-delay for writing to transport.
    catch --unwind=(: on-read-write-error_ it):
      with-timeout max-progress-delay:
        write-lock_.do: transport_.write msg

  run -> none:
    try:
      while true:
        response := transport_.read
        // Stop if transport was closed.
        if not response:
          logger_.debug "underlying transport closed the connection"
          return
        if not sessions_.dispatch-response response:
          response.message.payload.drain
          logger_.warn "unpaired response"
    finally:
      close

monitor Sessions_:
  sessions_ ::= {:}

  sequence-number_ := 0

  enter token:
    sessions_.update token --if-absent=null: throw "INVALID_TOKEN"

  leave token:
    sessions_.remove token

  get-response token:
    response := null
    await: response = sessions_.get token --if-absent=: Response.error null SESSION-CLOSED-ERROR
    if sessions_.contains token: sessions_[token] = null
    return response

  dispatch-response response:
    // Wait for the current message to be processed.
    await: not sessions_.get response.token
    sequence-number_++
    sessions_.update response.token --if-absent=(:return false): response
    return true

  abort error:
    // Terminate non-completed sessions with an closed error.
    sessions_.map --in-place: | token response |
      response ? response : Response.error null error
