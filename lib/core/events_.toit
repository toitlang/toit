// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

// TODO(4228): This monitor is used internally for resource managements and
//             should not be part of the public interface.
monitor ResourceState_:
  constructor .group_ .resource_:
    register-monitor-notifier_ this group_ resource_
    add-finalizer this:: dispose

  group: return group_
  resource: return resource_

  /**
  Sets the $callback that is called with the state when the resource is
    notified.

  Notifications happen when the state changes, but also on timeouts and
    task cancelation, so the state may be unchanged.

  The callback runs in a separate task, so it is allowed to block, for
    example by logging through a log service. Callbacks for this resource
    run in order and never concurrently. Notifications that arrive while
    the callback runs lead to one more call with the accumulated state.
  */
  set-callback callback/Lambda -> none:
    callback_ = callback

  wait-for-state bits:
    return wait-for-state_ bits

  wait:
    return wait-for-state_ 0x3fff_ffff

  clear:
    state_ = 0

  clear-state bits:
    state_ &= ~bits

  dispose:
    if resource_:
      unregister-monitor-notifier_ group_ resource_
      resource_ = null
      group_ = null
      callback_ = null
      remove-finalizer this

  /**
  Called on timeouts and when the state changes because of the call
    to $register-monitor-notifier_ in the constructor.

  Runs inline in the message processing loop, so it must not block.
  */
  notify_:
    try:
      resource := resource_
      if resource:
        state_ |= read-state_ group_ resource
        if callback_: schedule-callback_
    finally:
      // Always call the super implementation to avoid getting
      // into a situation, where timeouts might be ignored.
      super

  schedule-callback_ -> none:
    callback-pending_ = true
    if callback-running_: return
    // Creating a task does not yield, so the new task cannot run before
    // the flag is set.
    task --name="Resource state callback" --no-background:: run-callbacks_
    callback-running_ = true

  run-callbacks_ -> none:
    try:
      while callback-pending_:
        callback-pending_ = false
        callback := callback_
        if not callback: return
        callback.call state_
    finally:
      callback-running_ = false

  wait-for-state_ bits:
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
  callback_/Lambda? := null
  callback-pending_/bool := false
  callback-running_/bool := false
  state_ := 0

read-state_ module id:
  #primitive.events.read-state

register-monitor-notifier_ monitor/__Monitor__? module id -> none:
  #primitive.events.register-monitor-notifier

unregister-monitor-notifier_ module id -> none:
  #primitive.events.unregister-monitor-notifier
