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

/**
A system message handler that can deal with the out-of-memory error of its
  own $SystemMessageHandler_.on-message.
*/
interface SystemMessageOutOfMemoryHandler_:
  /**
  Called when the handler of the $message of the $type from the process with
    group ID $gid and process ID $pid ran out of memory (it could not grow
    the task's stack or allocate).

  Completes the message without memory if it can: the RPC request handler
    (RpcBroker) sends an OUT_OF_MEMORY error reply, unless the request was
    enqueued. Throws an out-of-memory error if it can't; the message is then
    kept and handled again (see $process-messages_).
  */
  on-out-of-memory type/int gid/int pid/int message/any -> none

/** Flag to track if we're currently processing messages. */
is-processing-messages_ := false

/**
A message that was taken from the mailbox but couldn't be handled because
  this process ran out of memory (an RPC handler and its
  $SystemMessageOutOfMemoryHandler_.on-out-of-memory both ran out of memory,
  or the processing ran out of memory before it handed the message over).
  Every call of $process-messages_ handles it again first.

Messages are taken from the mailbox before they are handled, so without it
  such a message would be lost: an RPC caller would wait for a lost reply
  forever, and a client for the reply to a lost request. (A message that
  can't be decoded for lack of memory stays in the mailbox.)
*/
deferred-message_ := null

/**
The message $process-messages_ is handing over to its handler. Kept as
  $deferred-message_ if the processing is unwound before that is done.
*/
received-message_ := null

/**
Whether the RPC message being handled is $deferred-message_, handled again.
The request handler (RpcBroker) then checks whether the earlier attempt
  enqueued the request before it ran out of memory.
*/
is-retrying-rpc-message_ := false

/**
Whether the $exception is one of the errors of an allocation that failed
  because the process (or the system) is out of memory.
*/
is-out-of-memory-error_ exception -> bool:
  return exception == "OUT_OF_MEMORY"
      or exception == "MALLOC_FAILED"
      or exception == "ALLOCATION_FAILED"

// We cache a message processor, so we don't have to keep allocating
// new tasks for processing messages all the time.
message-processor_/MessageProcessor_ := MessageProcessor_ null

/**
Processes the incoming messages sent to tasks in this process.

If we're already processing messages in another task, there is
  no need to take any action here.

A message that can't be handled for lack of memory is kept in
  $deferred-message_ (one at a time) and handled again, first, by the next
  call. While a message is kept, the other messages stay in the mailbox and
  every call ends with an out-of-memory error for the task that processes
  the messages, as for a message that can't be decoded (which stays in the
  mailbox): a process with a kept message can't go to sleep, its tasks learn
  that it is out of memory, and no message is lost.

Without $out-of-memory-error, it returns instead of throwing these errors
  (also the error of a message that can't be decoded): the task that yields
  or suspends while other tasks run leaves them to those.
*/
process-messages_ --out-of-memory-error/bool=true:
  if is-processing-messages_: return
  // Without messages the code below would do nothing (and need no try).
  if not deferred-message_ and not task-has-messages_: return
  is-processing-messages_ = true

  try:
    message := deferred-message_
    if message:
      deferred-message_ = null
      received-message_ = message
      is-retrying-rpc-message_ = true
      handled := false
      // Out of memory before the message was handed over: still kept.
      catch --unwind=(: not is-out-of-memory-error_ it):
        handled = dispatch-message_ message
      is-retrying-rpc-message_ = false
      received-message_ = null
      if not handled: deferred-message_ = message
    // While a message is kept, the others stay in the mailbox, as behind a
    // message that can't be decoded: none is lost.
    while not deferred-message_ and task-has-messages_:
      if out-of-memory-error:
        message = task-receive-message_
      else:
        // The message stays in the mailbox if it can't be decoded.
        failed := catch --unwind=(: not is-out-of-memory-error_ it):
          message = task-receive-message_
          received-message_ = message
        if failed: break
      // Kept if the processing is unwound before it handed the message
      // over: nothing between the receive and this store can fail (there is
      // no call in between).
      received-message_ = message
      handled := false
      catch --unwind=(: not is-out-of-memory-error_ it):
        handled = dispatch-message_ message
      received-message_ = null
      if not handled: deferred-message_ = message
    if deferred-message_ and out-of-memory-error: throw "OUT_OF_MEMORY"
  finally:
    received := received-message_
    if received:
      received-message_ = null
      if not deferred-message_: deferred-message_ = received
    is-processing-messages_ = false
    is-retrying-rpc-message_ = false

/**
Hands the $message over to its handler.

Returns false if it could not be handled for lack of memory.
*/
dispatch-message_ message -> bool:
  if message is __Monitor__:
    // Runs inline and must not block: the message processing is the only
    // reader of the messages, including the ones that would unblock it.
    message.notify_
    return true
  else if not message:
    // Under certain conditions messages can be canceled while
    // enqueued. Such messages are returned as null. Skip them.
    return true

  handled := true
  // The message processing can be called on a canceled task
  // when it is terminating. We need to make sure that the
  // handler code can run even in that case, so we do it in
  // a critical section and we do not care about the current
  // task's deadline if any.
  critical-do --no-respect-deadline:
    if message is Array_:
      type := message[0]
      if type == SYSTEM-RPC-REQUEST_ or type == SYSTEM-RPC-REPLY_:
        handled = MessageProcessor_.invoke-handler type message
      else:
        processor := message-processor_
        if not processor.run message:
          processor = MessageProcessor_ message
          message-processor_ = processor
        // Handed over: the processor handles it.
        received-message_ = null
        processor.detach-if-not-done_
    else if message is Lambda:
      pending-finalizers_.add message
      received-message_ = null
    else:
      assert: false
  return handled

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

  /**
  Calls the handler of the message.

  Returns false if the handler ran out of memory (it could not grow the
    task's stack or allocate) and could not complete the message without
    memory ($SystemMessageOutOfMemoryHandler_), true otherwise.
  */
  static invoke-handler type/int message/Array_ -> bool:
    handler ::= system-message-handlers_.get type --if-absent=:
      // Sandboxed processes can't write to stdout; they just drop the
      // message.
      catch: print_ "WARNING: unhandled system message $type"
      return true
    gid ::= message[1]
    pid ::= message[2]
    arguments ::= message[3]
    // The message comes from another process. An exception in its handler
    // must not unwind the task that happens to process the messages: that
    // would let any process that can send to us kill one of our tasks (and
    // with it this process).
    // An out-of-memory error is not traced (printing a trace needs memory).
    exception := catch --trace=(: not is-out-of-memory-error_ it):
      handler.on-message type gid pid arguments
    if not is-out-of-memory-error_ exception: return true
    // The handler ran out of memory, after the message was taken from the
    // mailbox. A sender can't make this happen on purpose: the RPC handlers
    // drop malformed messages without throwing, so they only fail like this
    // when this process is out of memory. Lost, an RPC reply would leave its
    // caller waiting forever, and a request its client.
    if handler is not SystemMessageOutOfMemoryHandler_: return false
    exception = catch --trace=(: not is-out-of-memory-error_ it):
      (handler as SystemMessageOutOfMemoryHandler_).on-out-of-memory type gid pid arguments
    return not is-out-of-memory-error_ exception

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
