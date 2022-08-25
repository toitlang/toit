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
  count_ /int := ?
  limit_ /int?

  /**
  Constructs a semaphore with an initial $count and an optional $limit.

  When the $limit is reached, further attempts to increment the
    counter using $up are ignored and leaves the counter unchanged.
  */
  constructor --count/int=0 --limit/int?=null:
    if count < 0: throw "INVALID_ARGUMENT"
    if limit and (limit < 1 or count > limit): throw "INVALID_ARGUMENT"
    limit_ = limit
    count_ = count

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

  /** The current count of the semaphore. */
  count -> int:
    return count_

/**
A signal synchronization primitive.

# Inheritance
This class must not be extended.
*/
monitor Signal:
  current_ /int := 0
  awaited_ /int := 0

  /**
  Waits until the signal has been raised.

  Raises that occur before $wait has been called are not taken into
    account, so care must be taken to avoid losing information.
  */
  wait -> none:
    wait_: true

  /**
  Waits until the given $condition returns true.

  The $condition is evaluated on entry.

  This task is blocked until the $condition returns true.

  The condition is re-evaluated (on this task) whenever the signal has been raised.
  */
  wait [condition] -> none:
    if condition.call: return
    wait_ condition

  /**
  Raises the signal and unblocks the tasks that are already waiting.

  If $max is provided and not null, no more than $max tasks are
    woken up in the order in which they started waiting (FIFO).
    The most common use case is to wake waiters up one at a time.
  */
  raise --max/int?=null -> none:
    if max:
      if max < 1: throw "INVALID_ARGUMENT"
      current_ = min awaited_ (current_ + max)
    else:
      current_ = awaited_

  // Helper method for condition waiting.
  wait_ [condition] -> none:
    while true:
      awaited := awaited_
      if current_ == awaited:
        // No other task is waiting for this signal to be raised,
        // so it is safe to reset the counters. This helps avoid
        // the ever increasing counter issue that may lead to poor
        // performance in (very) extreme cases.
        current_ = awaited = 0
      awaited_ = ++awaited
      await: current_ >= awaited
      if condition.call: return

/**
A synchronization gate.

The gate can be open or closed. When a task tries to $enter, it waits
  until the gate is open.
*/
class Gate:
  signal_ /Signal ::= Signal
  locked_ /bool := ?

  /**
  Constructs a new gate.

  If $unlocked is true, starts with the gate open.
  */
  constructor --unlocked/bool=false:
    locked_ = not unlocked

  /**
  Unlocks the gate, allowing tasks to enter.

  Does nothing if the gate is already unlocked.
  */
  unlock -> none:
    if not is_locked: return
    locked_ = false
    signal_.raise

  /**
  Lockes the gate.

  Any task that is trying to $enter will block until the gate is opened again.
  */
  lock:
    locked_ = true

  /**
  Enters the gate.

  This method blocks until the gate is open.
  */
  enter -> none:
    signal_.wait: is_unlocked

  /**
  Whether the gate is unlocked.
  */
  is_unlocked -> bool: return not locked_

  /**
  Whether the gate is locked.
  */
  is_locked -> bool: return locked_

/**
A one-way communication channel between tasks.
Multiple messages (objects) can be sent, and the capacity indicates how many
  unreceived message it can buffer.

# Inheritance
This class must not be extended.
*/
monitor Channel:
  buffer_ ::= ?
  start_ := 0
  size_ := 0

  /** Constructs a channel with a buffer of the given $capacity. */
  constructor capacity:
    if capacity <= 0: throw "INVALID_ARGUMENT"
    buffer_ = List capacity

  /**
  Sends a message with the $value on the channel.
  This operation may block if the buffer capacity has been reached. In that
    case, this task waits until another task calls $receive.
  If there are tasks blocked waiting for a value (with $receive), then one of
    them is woken up and receives the $value.
  */
  send value/any -> none:
    await: size_ < buffer_.size
    index := (start_ + size_) % buffer_.size
    buffer_[index] = value
    size_++

  /**
  Sends a message with the result of calling the given $block.
  This operation may block if the buffer capacity has been reached. In that
    case, this task waits until another task calls $receive. The block is
    only called when the channel has the capacity to buffer a message.
  If there are tasks blocked waiting for a value (with $receive), then one of
    them is woken up and receives the sent value.
  */
  send [block] -> none:
    await: size_ < buffer_.size
    index := (start_ + size_) % buffer_.size
    buffer_[index] = block.call
    size_++

  /**
  Tries to send a message with the $value on the channel. This operation never blocks.
  If there are tasks blocked waiting for a value (with $receive), then one of
    them is woken up and receives the $value.

  Returns true if the message was successfully delivered to the channel. Returns false
    if the channel is full and the message was not delivered
  */
  try_send value/any -> bool:
    if size_ >= buffer_.size: return false
    index := (start_ + size_) % buffer_.size
    buffer_[index] = value
    size_++
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
    if not blocking and size_ == 0: return null
    await: size_ > 0
    value := buffer_[start_]
    start_ = (start_ + 1) % buffer_.size
    size_--
    return value

  /**
  The capacity of the channel.
  */
  capacity -> int: return buffer_.size

  /**
  The amount of messages that are currently queued in the channel.
  */
  size -> int: return size_

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
