// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import monitor

/** Makes the current task sleep for the $duration. */
sleep duration/Duration:
  sleeper_.sleep_until_ (Time.monotonic_us + duration.in_us)

/** Makes the current task sleep for the given $ms of milliseconds. */
sleep --ms/int:
  sleeper_.sleep_until_ (Time.monotonic_us + ms * 1000)

/**
Timer resource group.

The resource group is used by the timer primitives to keep track of timers
  in this process.
*/
timer_resource_group_ ::= timer_init_

/** Sleeper monitor. */
sleeper_/Sleeper_ ::= Sleeper_

/**
Internal sleeper monitor to implement $sleep functionality.
*/
monitor Sleeper_:
  /**
  Sleep until $wakeup.
  */
  sleep_until_ wakeup/int -> none:
    self := task
    // Eagerly throw if we trying to sleep past the task deadline.
    deadline := self.deadline
    if deadline and deadline < wakeup: throw DEADLINE_EXCEEDED_ERROR
    // Acquire a suitable timer. These are often reused, so this is
    // unlikely to allocate.
    timer ::= self.acquire_timer_ this
    try:
      is_non_critical ::= self.critical_count_ == 0
      while true:
        // Check for task cancelation and timeout.
        if is_non_critical and self.is_canceled_: throw CANCELED_ERROR
        if Time.monotonic_us >= wakeup: return
        // Arm the timer and wait until we're notified. We might be notified
        // too early (spurious wakeup), so we arm the timer on every iteration.
        timer.arm wakeup
        await_ self
    finally:
      self.release_timer_ timer

/**
Internal timer used by sleep to wake up at the appropriate time.
*/
class Timer_:
  /** Timer resource. */
  timer_ ::= ?

  /**
  Constructs a timer with an internal timer resource.
  */
  constructor:
    timer_ = timer_create_ timer_resource_group_

  close:
    timer_delete_ timer_resource_group_ timer_

  arm deadline/int -> none:
    timer_arm_ timer_ deadline

  set_target monitor/__Monitor__ -> none:
    register_object_notifier_ monitor timer_resource_group_ timer_

  clear_target -> none:
    // We're reusing the timers, so it is faster to clear out the
    // monitor object on the notifier than it is to clear out the
    // whole notifier structure. This way, we typically do not have
    // to allocate when calling $set_target and instead we just
    // update the monitor reference in the notifier.
    register_object_notifier_ null timer_resource_group_ timer_

/**
Initiates the timer resource group.
Must only be called once in each process.
*/
timer_init_:
  #primitive.timer.init

/** Creates a timer resource attached to $timer_resource_group. */
timer_create_ timer_resource_group:
  #primitive.timer.create

/**
Arm $timer for notification in $us microseconds.
The $timer resource is notified when the time has elapsed.
*/
timer_arm_ timer us:
  #primitive.timer.arm

/** Delete the $timer resource from the $timer_resource_group. */
timer_delete_ timer_resource_group timer:
  #primitive.timer.delete
