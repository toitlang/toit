// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

import monitor

import .verbose

/**
Decides when compiler actions run.

All compiler work of the server goes through this class: $run executes an
  action as soon as a compiler slot is free, and $schedule debounces and
  coalesces actions that are triggered in bursts, like the analysis after
  every keystroke. Heuristics about how often and how many compilers run
  live here and not in the server.
*/
class CompilerScheduler:
  slots_ /Slots_ ::= Slots_
  /// Tasks that currently hold a slot. Nested $run calls reuse the slot.
  slot-holders_ /List ::= []
  /// Bursts of scheduled actions that are still being handled, keyed by id.
  bursts_ /Map ::= {:}
  /// Called when the last pending burst of scheduled actions has finished.
  on-idle /Lambda? := null
  /// How long a burst must be quiet before a scheduled action runs. A value <= 0 disables debouncing.
  debounce-ms /int := ?

  constructor --max-concurrent/int --.debounce-ms/int:
    slots_.limit = max-concurrent

  /// Sets how many compiler actions may run at the same time. A value <= 0 means no limit.
  max-concurrent= value/int -> none:
    slots_.limit = value

  /// Whether no scheduled action is pending or running.
  is-idle -> bool:
    return bursts_.is-empty

  /**
  Runs the compiler action $block as soon as a compiler slot is free.

  The $id names the kind of action, for example "completion".
  A nested call from within a running action reuses the slot of that action.

  Returns the result of the $block.
  */
  run --id/string [block] -> any:
    current := Task.current
    if slot-holders_.contains current: return block.call
    verbose: "Waiting for compiler slot: $id"
    slots_.acquire
    slot-holders_.add current
    try:
      verbose: "Running compiler action: $id"
      return block.call
    finally:
      critical-do:
        slot-holders_.remove current
        slots_.release

  /**
  Schedules the compiler $action for the given $id and $arg.

  Calls with the same $id are coalesced into bursts. The first call of a
    burst runs the $action right away with a list containing just $arg, so
    that a single change gets feedback without delay. Calls that follow
    within the debounce delay of each other are collected. Once the burst has
    been quiet for that long, the $action is called once with all collected
    args. Equal args are only passed once.

  The $action takes a list of args. All actions scheduled under the same $id
    must be interchangeable, since only one of them is used for a coalesced run.
  */
  schedule --id/string --arg/any action/Lambda -> none:
    if debounce-ms <= 0:
      run --id=id: action.call [arg]
      return

    deadline-us := Time.monotonic-us + debounce-ms * 1_000
    burst/Burst_? := bursts_.get id
    if burst:
      burst.add arg action deadline-us
      return

    burst = Burst_ action deadline-us
    bursts_[id] = burst
    task:: catch --trace:
      try:
        run --id=id: action.call [arg]
        while true:
          // Just keep sleeping until we wake up after the deadline.
          remaining-us := burst.deadline-us - Time.monotonic-us
          if remaining-us > 0:
            sleep (Duration --us=remaining-us)
            continue
          // The burst has been quiet for long enough. Run what accumulated
          // while we were sleeping (or running). If nothing did, the burst is over.
          if burst.args.is-empty: break
          args := List.from burst.args
          burst.args.clear
          run --id=id: burst.action.call args
      finally:
        critical-do:
          // Calls that arrive from here on start a new burst.
          bursts_.remove id
          if bursts_.is-empty and on-idle: on-idle.call

class Burst_:
  args /Set ::= {}
  action /Lambda := ?
  /// The monotonic time at which the burst is considered quiet.
  deadline-us /int := ?

  constructor .action .deadline-us:

  add arg/any action/Lambda deadline-us/int -> none:
    args.add arg
    this.action = action
    this.deadline-us = deadline-us

monitor Slots_:
  /// Max number of slots, <= 0 means no limit.
  limit_ /int := 0
  taken_ /int := 0

  // A method instead of a plain field, so that the monitor wakes up waiters.
  limit= value/int -> none:
    limit_ = value

  acquire -> none:
    await: limit_ <= 0 or taken_ < limit_
    taken_++

  release -> none:
    taken_--
