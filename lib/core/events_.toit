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
  */
  notify_:
    resource := resource_
    if resource:
      state := state_ | (read-state_ group_ resource)
      state_ = state
      callback := callback_
      if callback:
        callback.call state
    // Always call the super implementation to avoid getting
    // into a situation, where timeouts might be ignored.
    super

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
  state_ := 0

read-state_ module id:
  #primitive.events.read-state

register-monitor-notifier_ monitor/__Monitor__? module id -> none:
  #primitive.events.register-monitor-notifier

unregister-monitor-notifier_ module id -> none:
  #primitive.events.unregister-monitor-notifier
