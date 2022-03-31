// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

// TODO(4228): This monitor is used internally for resource managements and
//             should not be part of the public interface.
monitor ResourceState_:
  constructor .group_ .resource_:
    register_monitor_notifier_ this group_ resource_
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
      unregister_monitor_notifier_ group_ resource_
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

read_state_ module id:
  #primitive.events.read_state

register_monitor_notifier_ monitor/__Monitor__ module id -> none:
  #primitive.events.register_monitor_notifier

unregister_monitor_notifier_ module id -> none:
  #primitive.events.unregister_monitor_notifier
