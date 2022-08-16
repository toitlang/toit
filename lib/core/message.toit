// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

// System message types.
SYSTEM_TERMINATED_     ::= 0
SYSTEM_SPAWNED_        ::= 1
SYSTEM_MIRROR_MESSAGE_ ::= 2  // Used for sending stack traces and profile information.

// System message types for service RPCs.
SYSTEM_RPC_REQUEST_         ::= 3
SYSTEM_RPC_REPLY_           ::= 4
SYSTEM_RPC_CANCEL_          ::= 5
SYSTEM_RPC_NOTIFY_          ::= 6
SYSTEM_RPC_NOTIFY_RESOURCE_ ::= 7

/**
Sends the $message to the system with the $type.
It must be possible to encode the $message with the built-in
primitive message encoder.

Returns a status code:
* 0: Message OK
* 1: No such receiver
*/
system_send_ type/int message:
  return process_send_ -1 type message

/**
Sends the $message with $type to the process identified by $pid.
It must be possible to encode the $message with the built-in
primitive message encoder.

Returns a status code:
- 0: Message OK
- 1: No such receiver
*/
process_send_ pid/int type/int message:
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
          lambda := ::
            type ::= message[0]
            handler ::= system_message_handlers_.get type
            if handler:
              gid ::= message[1]
              pid ::= message[2]
              arguments ::= message[3]
              message = null  // Allow garbage collector to free.
              handler.on_message type gid pid arguments
            else:
              print_ "WARNING: unhandled system message $type"

          processor := message_processor_
          if not processor.run lambda:
            processor = MessageProcessor_ lambda
            message_processor_ = processor
          processor.detach_if_necessary_

        else if message is Lambda:
          pending_finalizers_.add message
        else:
          assert: false
  finally:
    is_processing_messages_ = false

monitor MessageProcessor_:
  static IDLE_TIME_MS /int ::= 100

  lambda_/Lambda? := null
  task_/Task_? := null

  constructor .lambda_:
    // The task code runs outside the monitor, so the monitor
    // is unlocked when the messages are being processed.
    task_ = create_task_ "Message processing task" TASK_MESSAGE_PROCESSING_::
      try:
        self ::= Task.current
        while not self.is_canceled:
          next ::= wait_for_next
          if not next: break
          try:
            next.call
          finally:
            lambda_ = null
      finally:
        task_ = null

  run lambda/Lambda -> bool:
    if lambda_ or not task_: return false
    lambda_ = lambda
    return true

  detach_if_necessary_:
    task ::= task_
    if task: task_transfer_to_ task false
    // If we come back here and the lambda hasn't been
    // cleared out, we detach this processor from the
    // task so it stops when it is done with the lambda.
    if lambda_: task_ = null

  wait_for_next -> Lambda?:
    deadline ::= Time.monotonic_us + IDLE_TIME_MS * 1_000
    success ::= try_await --deadline=deadline: task_ == null or lambda_ != null
    return success ? lambda_ : null

task_has_messages_ -> bool:
  #primitive.core.task_has_messages

task_receive_message_:
  #primitive.core.task_receive_message
