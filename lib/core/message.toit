// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

// System message types.
SYSTEM_TERMINATED_ ::= 0
SYSTEM_SPAWNED_    ::= 1
SYSTEM_TRACE_      ::= 2  // Stack traces, histograms, and profiling information.

// System message types for service RPCs.
SYSTEM_RPC_REQUEST_         ::= 3
SYSTEM_RPC_REPLY_           ::= 4
SYSTEM_RPC_CANCEL_          ::= 5
SYSTEM_RPC_NOTIFY_          ::= 6
SYSTEM_RPC_NOTIFY_RESOURCE_ ::= 7

/**
Sends the $message with $type to the process identified by $pid.
It must be possible to encode the $message with the built-in
  primitive message encoder.
May throw "NESTING_TOO_DEEP" for deep or cyclic data structures.
May throw a serialization failure.
May throw "MESSAGE_NO_SUCH_RECEIVER" if the pid is invalid.
*/
process_send_ pid/int type/int message:
  #primitive.core.process_send:
    if it is List and it.size != 0 and it[0] is int:
      serialization_failure_ it[0]
    throw it

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
  on_message type/int gid/int pid/int message/any -> none

/**
Sets the $handler as the system message handler for message of the $type.
*/
set_system_message_handler_ type/int handler/SystemMessageHandler_:
  system_message_handlers_[type] = handler

/** Flag to track if we're currently processing messages. */
is_processing_messages_ := false

// We cache a message processor, so we don't have to keep allocating
// new tasks for processing messages all the time.
message_processor_/MessageProcessor_ := MessageProcessor_ null

/**
Processes the incoming messages sent to tasks in this process.

If we're already processing messages in another task, there is
  no need to take any action here.
*/
process_messages_:
  if is_processing_messages_: return
  is_processing_messages_ = true

  try:
    while task_has_messages_:
      message := task_receive_message_
      if message is __Monitor__:
        message.notify_
        continue
      else if not message:
        // Under certain conditions messages can be canceled while
        // enqueued. Such messages are returned as null. Skip them.
        continue

      // The message processing can be called on a canceled task
      // when it is terminating. We need to make sure that the
      // handler code can run even in that case, so we do it in
      // a critical section and we do not care about the current
      // task's deadline if any.
      critical_do --no-respect_deadline:
        if message is Array_:
          type := message[0]
          if type == SYSTEM_RPC_REQUEST_ or type == SYSTEM_RPC_REPLY_:
            MessageProcessor_.invoke_handler type message
          else:
            processor := message_processor_
            if not processor.run message:
              processor = MessageProcessor_ message
              message_processor_ = processor
            processor.detach_if_not_done_
        else if message is Lambda:
          pending_finalizers_.add message
        else:
          assert: false
  finally:
    is_processing_messages_ = false

monitor MessageProcessor_:
  static IDLE_TIME_MS /int ::= 100

  task_/Task? := null
  message_/Array_? := null

  constructor .message_:
    // The task code runs outside the monitor, so the monitor
    // is unlocked when the messages are being processed.
    task_ = task --name="Message processing task" --no-background::
      try:
        // Message handlers run in critical regions, so they
        // cannot be canceled and they avoid yielding after
        // monitor operations. This makes it more likely that
        // they will complete quickly.
        critical_do:
          while true:
            next := message_
            if not next:
              next = wait_for_next
              if not next: break
            try:
              invoke_handler next[0] next
            finally:
              message_ = null
      finally:
        task_ = null

  static invoke_handler type/int message/Array_ -> none:
    handler ::= system_message_handlers_.get type --if_absent=:
      print_ "WARNING: unhandled system message $type"
      return
    gid ::= message[1]
    pid ::= message[2]
    arguments ::= message[3]
    handler.on_message type gid pid arguments

  run message/Array_ -> bool:
    if message_ or not task_: return false
    message_ = message
    return true

  detach_if_not_done_ -> none:
    task/any := task_
    if task: task_transfer_to_ task false
    // If we come back here and the message hasn't been cleared out,
    // we detach this message processor by clearing out the task
    // field. This forces it to stop when it is done with the message.
    if message_: task_ = null

  wait_for_next -> Array_?:
    deadline ::= Time.monotonic_us + IDLE_TIME_MS * 1_000
    try_await --deadline=deadline: message_ or not task_
    // If we got a message, we must return it and deal with even if we timed out.
    return message_

task_has_messages_ -> bool:
  #primitive.core.task_has_messages

task_receive_message_:
  #primitive.core.task_receive_message
