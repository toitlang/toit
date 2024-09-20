// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

// System message types.
SYSTEM-TERMINATED_ ::= 0
SYSTEM-SPAWNED_    ::= 1
SYSTEM-TRACE_      ::= 2  // Stack traces, histograms, and profiling information.

// System message types for service RPCs.
SYSTEM-RPC-REQUEST_           ::= 3
SYSTEM-RPC-REPLY_             ::= 4
SYSTEM-RPC-CANCEL_            ::= 5
SYSTEM-RPC-NOTIFY-TERMINATED_ ::= 6
SYSTEM-RPC-NOTIFY-RESOURCE_   ::= 7

// System message types for external notifications.
SYSTEM-EXTERNAL-NOTIFICATION_ ::= 8

RESERVED-MESSAGE-TYPES_ ::= 64

/**
Sends the $message with $type to the process identified by $pid and
  returns whether the $message was delivered.

It must be possible to encode the $message with the built-in
  message encoder. Throws "NESTING_TOO_DEEP" for deep or cyclic
  data structures or a serialization error for unserializable
  messages.
*/
process-send_ pid/int type/int message -> bool:
  #primitive.core.process-send:
    if it is List and it.size != 0 and it[0] is int:
      serialization-failure_ it[0]
    throw it

/**
Returns the process ID for the process with the given external $id.

If no process with the external ID exists, returns -1.
*/
pid-for-external-id_ id/string -> int:
  #primitive.core.pid-for-external-id

/** Registered system message handlers for this process. */
system-message-handlers_ ::= {:}

interface SystemMessageHandler_:
  /**
  Handles the $message of the $type from the process with group ID $gid and
    process ID $pid.
  */
  on-message type/int gid/int pid/int message/any -> none

/**
Sets the $handler as the system message handler for message of the $type.
*/
set-system-message-handler_ type/int handler/SystemMessageHandler_:
  system-message-handlers_[type] = handler

/**
Removes the handler for the given $type.
*/
clear-system-message-handler_ type/int:
  system-message-handlers_.remove type

/** Flag to track if we're currently processing messages. */
is-processing-messages_ := false

// We cache a message processor, so we don't have to keep allocating
// new tasks for processing messages all the time.
message-processor_/MessageProcessor_ := MessageProcessor_ null

/**
Processes the incoming messages sent to tasks in this process.

If we're already processing messages in another task, there is
  no need to take any action here.
*/
process-messages_:
  if is-processing-messages_: return
  is-processing-messages_ = true

  try:
    while task-has-messages_:
      message := task-receive-message_
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
      critical-do --no-respect-deadline:
        if message is Array_:
          type := message[0]
          if type == SYSTEM-RPC-REQUEST_ or type == SYSTEM-RPC-REPLY_:
            MessageProcessor_.invoke-handler type message
          else:
            processor := message-processor_
            if not processor.run message:
              processor = MessageProcessor_ message
              message-processor_ = processor
            processor.detach-if-not-done_
        else if message is Lambda:
          pending-finalizers_.add message
        else:
          assert: false
  finally:
    is-processing-messages_ = false

monitor MessageProcessor_:
  static IDLE-TIME-MS /int ::= 100

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
        critical-do:
          while true:
            next := message_
            if not next:
              next = wait-for-next
              if not next: break
            try:
              invoke-handler next[0] next
            finally:
              message_ = null
      finally:
        task_ = null

  static invoke-handler type/int message/Array_ -> none:
    handler ::= system-message-handlers_.get type --if-absent=:
      print_ "WARNING: unhandled system message $type"
      return
    gid ::= message[1]
    pid ::= message[2]
    arguments ::= message[3]
    handler.on-message type gid pid arguments

  run message/Array_ -> bool:
    if message_ or not task_: return false
    message_ = message
    return true

  detach-if-not-done_ -> none:
    task/any := task_
    if task: task-transfer-to_ task false
    // If we come back here and the message hasn't been cleared out,
    // we detach this message processor by clearing out the task
    // field. This forces it to stop when it is done with the message.
    if message_: task_ = null

  wait-for-next -> Array_?:
    deadline ::= Time.monotonic-us + IDLE-TIME-MS * 1_000
    try-await --deadline=deadline: message_ or not task_
    // If we got a message, we must return it and deal with even if we timed out.
    return message_

task-has-messages_ -> bool:
  #primitive.core.task-has-messages

task-receive-message_:
  #primitive.core.task-receive-message
