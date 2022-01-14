// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import encoding.ubjson as ubjson
import .message_manual_decoding_

// Message types.
// Keep in sync with constants in process.h.
MESSAGE_INVALID_       ::= 0
MESSAGE_OBJECT_NOTIFY_ ::= 1
MESSAGE_SYSTEM_        ::= 2

// System message types.
SYSTEM_TERMINATED_              ::= 0
SYSTEM_MIRROR_MESSAGE_          ::= 2  // Used for sending stack traces and profile information.
SYSTEM_RPC_CHANNEL_LEGACY_      ::= 10

/**
Sends the $message to the system with the $type.
It must be possible to encode the $message as ubjson.

Returns a status code:
* 0: Message OK
* 1: No such receiver
*/
system_send_ type message:
  return system_send_bytes_
    type
    ubjson.encode message

/**
Sends the $bytes to the system with the $type.
If the $bytes are not an external byte array, then they are copied to one.
The $bytes must not be accessed once they have been sent.

Returns a status code:
- 0: Message OK
- 1: No such receiver
*/
system_send_bytes_ type/int bytes/ByteArray:
  return system_send_native_ type bytes

/**
Sends the $message with $type to the process identified by $pid.
It must be possible to encode the $message as ubjson.

Returns a status code:
- 0: Message OK
- 1: No such receiver
*/
process_send_ pid type message:
  return process_send_bytes_
    pid
    type
    ubjson.encode message

/**
Sends the $bytes with $type to the process identified by $pid.
If the $bytes are not an external byte array, then they are copied to an
  external byte array.

Returns a status code:
- 0: Message OK
- 1: No such receiver

If the return code is OK, then the $bytes are consumed.
*/
process_send_bytes_ pid/int type/int bytes/ByteArray:
  return process_send_native_ pid type bytes

/**
Sends a message byte array to the system process.
Returns a result code (OK, NO_SUCH_RECEIVER).
If the result is OK, the message byte array is consumed
and cannot be reused.
*/
system_send_native_ type message:
  #primitive.core.system_send

/**
Sends a message byte array to another process.
Returns a result code (OK, NO_SUCH_RECEIVER).
If the result is OK, the message byte array is consumed
and cannot be reused.
*/
process_send_native_ pid type message:
  #primitive.core.process_send

/** Registered system message handlers for this process. */
system_message_handlers_ ::= {:}

interface SystemMessageHandler_:
  /**
  Handles the $message of the $type from the process with group ID $gid and
    process ID $pid.

  # Inheritance
  Implementation of this method must not lead to message processing (that is calls to
    $process_messages_).
  */
  on_message type gid pid message

/**
Sets the $handler as the system message handler for message of the $type.
*/
set_system_message_handler_ type handler/SystemMessageHandler_:
  system_message_handlers_[type] = handler

/**
The system message handler for the $type.
*/
get_system_message_handler_ type:
  return system_message_handlers_.get type

/**
Processes the incoming messages sent to tasks in this process.

To avoid infinite recursions, processing of messages must not lead to further
  processing of messages.
*/
process_messages_:
  if is_processing_messages_: throw "RECURSIVE_MESSAGE_PROCESSING"
  is_processing_messages_ = true
  try:
    while true:
      message_type := task_peek_message_type_
      if message_type == MESSAGE_INVALID_: break
      received := task_receive_message_
      if message_type == MESSAGE_SYSTEM_:
        type ::= received[0]
        gid ::= received[1]
        pid ::= received[2]
        args ::= type == SYSTEM_RPC_CHANNEL_LEGACY_  ? received[3] : ubjson.decode received[3]
        received = null  // Allow garbage collector to free.
        system_message_handlers_.get type
          --if_present=: it.on_message type gid pid args
          --if_absent=:
            if type == SYSTEM_MIRROR_MESSAGE_:
              print_for_manually_decoding_ args
            else:
              print_ "WARNING: unhandled system message $type $args"
      else if message_type == MESSAGE_OBJECT_NOTIFY_:
        if received: received.notify_
      else:
        assert: false
  finally:
    is_processing_messages_ = false


task_peek_message_type_:
  #primitive.core.task_peek_message_type

task_receive_message_:
  #primitive.core.task_receive_message
