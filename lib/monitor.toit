// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
Synchronization primitives for coordinating and communicating between tasks.
Note that these monitors are not suitable for interprocess or network
  communication.  They are only for tasks within one process.
*/

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
  /**
  Receives the value.

  This method blocks until the value is available.
  Should be called at most once for each instance of the class.
  */
  get:
    await: has_value_
    return value_

  /**
  Sets the $value of the latch.

  Calling this method unblocks any task that is blocked in the $get method of
    the same instance, sending the $value to it.
  Future calls to $get return immediately and use this $value.
  Must be called at most once for each instance of the monitor.
  */
  set value:
    value_ = value
    has_value_ = true
  has_value_ := false
  value_ := null

/** A monitor that ensures an initializer is only called once. */
monitor Once:
  static STATE_UNINITIALIZED_ ::= 0
  static STATE_INITIALIZED_   ::= 1
  static STATE_EXCEPTION_     ::= 2

  initializer_/Lambda? := ?
  state_ := STATE_UNINITIALIZED_
  value_ := null

  /**
  Constructs the once monitor with the given $initializer_.

  The $initializer_ must be a lambda.
  */
  constructor .initializer_:
    if not initializer_: throw "invalid argument"

  /**
  Gets the result of the initialization.

  Calls the initializer the first time this method is called.
  If the initialization throws an exception, then this methods throws that
    exception. Future attempts to get the value will run the initializer again.
  The trace of the initialization is printed but not rethrown.
  */
  get:
    if initializer_:
      exception := catch --trace: value_ = initializer_.call
      initializer_ = null
      if exception:
        state_ = STATE_EXCEPTION_
        value_ = exception
      else:
        state_ = STATE_INITIALIZED_
    if state_ == STATE_INITIALIZED_: return value_
    else: throw value_

/**
A semaphore synchronization primitive.

# Inheritance
This class must not be extended.
*/
monitor Semaphore:
  /**
  Increments an internal counter.

  Originally called the V operation.
  */
  up:
    count_++

  /**
  Decrements an internal counter.
  This method blocks until the counter is non-zero.

  Originally called the P operation.
  */
  down:
    await: count_ > 0
    count_--

  count_ := 0

/**
A one-way communication channel between tasks.
Multiple messages (objects) can be sent, and the capacity indicates how many
  unreceived message it can buffer.

# Inheritance
This class must not be extended.
*/
monitor Channel:
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
  send value:
    n := 0
    await:
      n = (p_ + 1) % buffer_.size
      n != c_
    buffer_[p_] = value
    p_ = n

  /**
  Receives a message from the channel.
  If no message is ready, and $blocking is true, blocks until another tasks
    sends a message through $send.
  If no message is ready, and $blocking is false, returns null.
  If multiple tasks are blocked waiting for a new value, then a $send call only
    unblocks one waiting task.
  The order in which waiting tasks are unblocked is unspecified.
  */
  receive --blocking/bool=true:
    if not blocking and c_ == p_: return null
    await: c_ != p_
    value := buffer_[c_]
    c_ = (c_ + 1) % buffer_.size
    return value

  buffer_ := ?
  c_ := 0
  p_ := 0

/**
A two-way communication channel between tasks with replies to each message.
  Multiple messages (objects) can be sent, but only one can be in flight at a
  time.

# Inheritance
This class must not be extended.
*/
monitor Mailbox:
  /**
  Sends the $message to another task.

  This operation blocks until the other task replies.
  */
  send message:
    await: state_ == 0
    state_ = 1
    message_ = message
    await: state_ == 3
    result := message_
    state_ = 0
    message_ = null
    return result

  /**
  Receives a message from another task.
  This operation blocks until the other task sends a message.
  This task must respond to the message, using $reply. Failure to do so leads
    to indefinitely blocked tasks.
  */
  receive:
    await: state_ == 1
    result := message_
    state_ = 2
    message_ = null
    return result

  /**
  Replies to the other task with a reply message (object).
  This unblocks the other task, which is waiting in $send.
  */
  reply message:
    assert: state_ == 2
    state_ = 3
    message_ = message

  state_ := 0  // 0 = ready, 1 = sent, 2 = received, 3 = replied
  message_ := null

// TODO(4228): This monitor is used internally for resource managements and
//             should not be part of the public interface.
monitor ResourceState_:
  constructor .group_ .resource_:
    register_object_notifier_ this group_ resource_
    add_finalizer this:: dispose

  group: return group_
  resource: return resource_

  wait_for_state bits:
    return wait_for_state_ bits

  wait:
    return wait_for_state_ 0xffffff

  clear:
    state_ = 0

  clear_state bits:
    state_ &= ~bits

  dispose:
    if resource_:
      unregister_object_notifier_ group_ resource_
      resource_ = null
      group_ = null
      remove_finalizer this

  // Called on timeouts and when the state changes because of the call
  // to [register_object_notifier] in the constructor.
  notify_:
    resource := resource_
    if resource:
      state := read_state_ group_ resource
      state_ |= state
    // Always call the super implementation to avoid getting
    // into a situation, where timeouts might be ignored.
    super

  wait_for_state_ bits:
    result := null
    if not resource_: return 0
    await:
      result = state_ & bits
      // Check if we got some of the right bits or if the resource
      // state was forcibly disposed through [dispose].
      not resource_ or result != 0
    if not resource_: return 0
    return result

  group_ := ?
  resource_ := ?
  state_ := 0

/**
A tracker that keeps a state and lets you wait for changes.

Used to notify some listeners of changes to a set of states.

The listener calls $StateTracker.wait_for_new_state with a set of
  key-values that are its current knowledge of the state. When the state
  changes, the $StateTracker.wait_for_new_state method returns with a new
  map, giving the current state.
The state is updated with $StateTracker.[]=.
*/
monitor StateTracker:
  states_ := {:}
  logs_ := {:}

  /**
  Waits for a new state.

  The given $known_state is the callers known state. It also indicates what
    keys of the state the caller is interested in. A new state must have some
    value different from the $known_state.
  */
  wait_for_new_state known_state/Map -> Map:
    result := null
    await:
      difference := false
      result = {:}
      known_state.do --keys: | key |
        if states_.contains key:
          value := states_.get key
          if known_state[key] != value: difference = true
          result[key] = value
        else if logs_.contains key:
          list := logs_.get key
          if not (list == known_state[key]):  // Pairwise == comparison.
            difference = true
          result[key] = list.copy
        else:
          result[key] = known_state[key]
      continue.await difference
    return result

  /**
  Stores $value in the state for the given $key.

  If the $key is already present, overwrites the previous value.
  Overwriting with a different value will notify listeners.
  */
  operator []= key value:
    states_[key] = value

  /**
  Increments the value associated with the $key by 1 (or the given $by).

  Used for implementing reference-count-like functionality.
  The count is started at 0 (1 after incrementing) if it did not already exist.

  If the $key exists, then its value must be an integer.
  */
  increment key --by=1:
    if not states_.contains key:
      states_[key] = 0
    states_[key] += by

  /**
  Decrements the value associated with the $key by 1 (or the given $by).

  For implementing reference-count-like functionality.
  It is an error if the key does not already exists or the value is not an integer.
  */
  decrement key --by=1:
    states_[key] -= by

  /**
  Adds the given $line to the log of this tracker stored under the key
    $subject.

  Once $retained_lines have been added, the oldest line is removed.

  Asking for the $subject in $wait_for_new_state returns a list with up to
    $retained_lines entries.
  */
  log --subject/string="log" line/string --retained_lines/int=8 -> none:
    list := logs_.get subject --init=: []
    if list.size < retained_lines:
      list.add line
    else:
      (list.size - 1).repeat:
        list[it] = list[it + 1]
      list[list.size - 1] = line

/**
Signal dispatcher.

Allow lambdas to be registered and unregistered from signals.

The lambdas registered for a specific signal are called when notifying the
  signal.
*/
class SignalDispatcher:
  handlers_ ::= {:}

  /**
  Registers the $lambda with the given $signal.

  If the lambda throws when it is called, then it $notify will throw.
  */
  register signal/int lambda/Lambda:
    set := handlers_.get signal --init=(: {})
    set.add lambda

  /** Unregisters the given $lambda from the $signal. */
  unregister signal/int lambda/Lambda:
    handlers_.get signal --if_present=:
      it.remove lambda
      if it.is_empty: handlers_.remove signal

  /**
  Calls all registrations for the given $signal.

  Registrations are called in an unspecified order, and if any called
    registration throws, then this method throws.
  */
  notify signal/int value=null:
    handlers_.get signal --if_present=:
      it.do:
        it.call value
