// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import monitor

/** Makes the current task sleep for the $duration. */
sleep duration/Duration:
  sleeper_.sleep-until_ (Time.monotonic-us + duration.in-us)

/** Makes the current task sleep for the given $ms of milliseconds. */
sleep --ms/int:
  sleeper_.sleep-until_ (Time.monotonic-us + ms * 1000)

/**
Timer resource group.

The resource group is used by the timer primitives to keep track of timers
  in this process.
*/
timer-resource-group_ ::= timer-init_

/** Sleeper monitor. */
sleeper_/Sleeper_ ::= Sleeper_

/**
Internal sleeper monitor to implement $sleep functionality.
*/
monitor Sleeper_:
  /**
  Sleep until $wakeup.
  */
  sleep-until_ wakeup/int -> none:
    self := Task_.current
    deadline := self.deadline
    if deadline and deadline < wakeup: wakeup = deadline
    // Acquire a suitable timer. These are often reused, so this is
    // unlikely to allocate.
    timer ::= self.acquire-timer_ this
    try:
      is-non-critical ::= self.critical-count_ == 0
      while true:
        // Check for task cancelation and timeout.
        if is-non-critical and self.is-canceled_: throw CANCELED-ERROR
        now := Time.monotonic-us
        if now >= wakeup:
          if deadline and now >= deadline: throw DEADLINE-EXCEEDED-ERROR
          return
        // Arm the timer and wait until we're notified. We might be notified
        // too early (spurious wakeup), so we arm the timer on every iteration.
        timer.arm wakeup
        await_ self
    finally:
      self.release-timer_ timer

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
    timer_ = timer-create_ timer-resource-group_

  close:
    timer-delete_ timer-resource-group_ timer_

  arm deadline/int -> none:
    timer-arm_ timer_ deadline

  set-target monitor/__Monitor__ -> none:
    register-monitor-notifier_ monitor timer-resource-group_ timer_

  clear-target -> none:
    // We're reusing the timers, so it is faster to clear out the
    // monitor object on the notifier than it is to clear out the
    // whole notifier structure. This way, we typically do not have
    // to allocate when calling $set_target and instead we just
    // update the monitor reference in the notifier.
    register-monitor-notifier_ null timer-resource-group_ timer_

/**
Initiates the timer resource group.
Must only be called once in each process.
*/
timer-init_:
  #primitive.timer.init

/** Creates a timer resource attached to $timer-resource-group. */
timer-create_ timer-resource-group:
  #primitive.timer.create

/**
Arm $timer for notification in $us microseconds.
The $timer resource is notified when the time has elapsed.
*/
timer-arm_ timer us:
  #primitive.timer.arm

/** Delete the $timer resource from the $timer-resource-group. */
timer-delete_ timer-resource-group timer:
  #primitive.timer.delete
