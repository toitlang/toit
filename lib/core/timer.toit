// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import monitor

/** Makes the current task sleep for the $duration. */
sleep duration/Duration:
  task.get_timer_.sleep duration.in_us

/** Makes the current task sleep for the given $ms of milliseconds. */
sleep --ms/int:
  task.get_timer_.sleep ms * 1000

/**
Timer resource group.

The resource group is used by the timer primitives to keep track of timers
  in this process.
*/
timer_resource_group_ ::= timer_init_

/**
Internal sleeper monitor to implement $sleep functionality.
*/
monitor Sleeper_:
  /**
  Sleep until $deadline.
  */
  sleep_until deadline/int:
    task_deadline := task.deadline
    if task_deadline and task_deadline < deadline:
      // We have a smaller task deadline, so this will throw.
      // Use await for common "throwing" behavior.
      await: false

    // Will not expire, use try_await_ directly do avoid throwing then expired.
    while (try_await_ deadline: false):


/**
Internal timer used by sleep to wake up at the appropriate time.
*/
class Timer_:
  /** Timer resource. */
  timer_ ::= ?
  /** Sleeper monitor. */
  sleeper_/Sleeper_ ::= Sleeper_

  /**
  Constructs a timer with an internal timer resource.
  */
  constructor:
    timer_ = timer_create_ timer_resource_group_

  close:
    timer_delete_ timer_resource_group_ timer_

  arm target deadline/int:
    register_object_notifier_ target timer_resource_group_ timer_
    timer_arm_ timer_ deadline

  /**
  Sleeps for $us microseconds.
  */
  sleep us:
    sleeper_.sleep_until
      Time.monotonic_us + us

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
Arm $timer for notification in $us micro seconds.
The $timer resource is notified when the time has elapsed.
*/
timer_arm_ timer us:
  #primitive.timer.arm

/** Delete the $timer resource from the $timer_resource_group. */
timer_delete_ timer_resource_group timer:
  #primitive.timer.delete
