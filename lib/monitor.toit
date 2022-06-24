// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
Synchronization primitives for coordinating and communicating between tasks.
Note that these monitors are not suitable for interprocess or network
  communication.  They are only for tasks within one process.
*/

// TODO(kasper): Update importers to use ResourceState from the core
// library instead.
export ResourceState_

/**
Mutual exclusion monitor.

Used to ensure mutual exclusion of calls to blocks.

# Inheritance
This class must not be extended.
*/
monitor Mutex:
  /**
  Calls the given $block exclusively.
  Other calls to this method are blocked until this method has returned.
  */
  do [block]: return block.call

/**
A latch that allows one task to wait until a value (object) has been provided
  by another task.

# Inheritance
This class must not be extended.
*/
monitor Latch:
  has_value_ / bool := false
  value_ := null

  /**
  Receives the value.

  This method blocks until the value is available.
  May be called multiple times.
  */
  get -> any:
    await: has_value_
    return value_

  /**
  Sets the $value of the latch.

  Calling this method unblocks any task that is blocked in the $get method of
    the same instance, sending the $value to it.
  Future calls to $get return immediately and use this $value.
  Must be called at most once for each instance of the monitor.
  */
  set value/any -> none:
    value_ = value
    has_value_ = true

  /** Whether this latch has already a value set. */
  has_value -> bool:
    return has_value_

/**
A semaphore synchronization primitive.

# Inheritance
This class must not be extended.
*/
monitor Semaphore:
  count_ /int := 0
  limit_ /int?

  /**
  Constructs a semaphore with an initial $count and an optional $limit.
  */
  constructor --count/int=0 --limit/int?=null:
    if limit and (limit < 1 or count > limit): throw "INVALID_ARGUMENT"
    limit_ = limit

  /**
  Increments an internal counter.

  Originally called the V operation.
  */
  up -> none:
    count := count_
    limit := limit_
    if limit and count >= limit: return
    count_ = count + 1

  /**
  Decrements an internal counter.
  This method blocks until the counter is non-zero.

  Originally called the P operation.
  */
  down -> none:
    await: count_ > 0
    count_--

/**
A signal synchronization primitive.

# Inheritance
This class must not be extended.
*/
monitor Signal:
  current_ /int := 0
  awaited_ /int := 0

  /**
  Waits until the signal has been raised while this task has been waiting.

  Raises that occur before $wait has been called are not taken into
    account, so care must be taken to avoid losing information.
  */
  wait -> none:
    wait_: true

  /**
  Waits until the given $condition returns true.

  The $condition is evaluated on entry, but if it returns false initially, it
    is only re-evaluated when the signal has been raised and the current task
    has been unblocked.
  */
  wait [condition] -> none:
    if condition.call: return
    wait_ condition

  /**
  Raises the signal and unblocks the tasks that are already waiting.

  If $count is provided and not null, no more than $count tasks are
    unblocked.
  */
  raise --count/int?=null -> none:
    if count:
      if count < 1: throw "INVALID_ARGUMENT"
      current_ = min awaited_ (current_ + count)
    else:
      current_ = awaited_

  // Helper method for condition waiting.
  wait_ [condition] -> none:
    while true:
      awaited := awaited_
      if current_ == awaited:
        current_ = awaited = 0
      awaited_ = ++awaited
      await: current_ >= awaited
      if condition.call: return

/**
A one-way communication channel between tasks.
Multiple messages (objects) can be sent, and the capacity indicates how many
  unreceived message it can buffer.

# Inheritance
This class must not be extended.
*/
monitor Channel:
  buffer_ ::= ?
  c_ := 0
  p_ := 0

  /** Constructs a channel with a buffer of the given $capacity. */
  constructor capacity:
    buffer_ = List capacity + 1

  /**
  Sends a message with the $value on the channel.
  This operation may block if the buffer capacity has been reached. In that
    case, this task waits until another task calls $receive.
  If there are tasks blocked waiting for a value (with $receive), then one of
    them is woken up and receives the $value.
  */
  send value/any -> none:
    n := 0
    await:
      n = (p_ + 1) % buffer_.size
      n != c_
    buffer_[p_] = value
    p_ = n

  /**
  Tries to send a message with the $value on the channel. This operation never blocks.
  If there are tasks blocked waiting for a value (with $receive), then one of
    them is woken up and receives the $value.

  Returns true if the message was successfully delivered to the channel. Returns false
    if the channel is full and the message was not delivered
  */
  try_send value/any -> bool:
    n := (p_ + 1) % buffer_.size
    if c_ == n: return false
    buffer_[p_] = value
    p_ = n
    return true

  /**
  Receives a message from the channel.
  If no message is ready, and $blocking is true, blocks until another tasks
    sends a message through $send.
  If no message is ready, and $blocking is false, returns null.
  If multiple tasks are blocked waiting for a new value, then a $send call only
    unblocks one waiting task.
  The order in which waiting tasks are unblocked is unspecified.
  */
  receive --blocking/bool=true -> any:
    if not blocking and c_ == p_: return null
    await: c_ != p_
    value := buffer_[c_]
    c_ = (c_ + 1) % buffer_.size
    return value

/**
A two-way communication channel between tasks with replies to each message.
  Multiple messages (objects) can be sent, but only one can be in flight at a
  time.

# Inheritance
This class must not be extended.
*/
monitor Mailbox:
  static STATE_READY_    / int ::= 0
  static STATE_SENT_     / int ::= 1
  static STATE_RECEIVED_ / int ::= 2
  static STATE_REPLIED_  / int ::= 3

  state_ / int := STATE_READY_
  message_ / any := null

  /**
  Sends the $message to another task.

  This operation blocks until the other task replies.
  */
  send message/any -> any:
    await: state_ == STATE_READY_
    state_ = STATE_SENT_
    message_ = message
    await: state_ == STATE_REPLIED_
    result := message_
    state_ = STATE_READY_
    message_ = null
    return result

  /**
  Receives a message from another task.
  This operation blocks until the other task sends a message.
  This task must respond to the message, using $reply. Failure to do so leads
    to indefinitely blocked tasks.
  */
  receive -> any:
    await: state_ == STATE_SENT_
    result := message_
    state_ = STATE_RECEIVED_
    message_ = null
    return result

  /**
  Replies to the other task with a reply message (object).
  This unblocks the other task, which is waiting in $send.
  */
  reply message/any -> none:
    if state_ != STATE_RECEIVED_: throw "No message received"
    state_ = STATE_REPLIED_
    message_ = message
