// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
Support for finalization.
*/

/**
Registers the given $lambda as a finalizer for the $object.

Calls the finalizer if all references to the object are lost. (See limitations below).

# Errors
It is an error to assign a finalizer to a smi or an instance that already has
  a finalizer (see $remove_finalizer).
It is also an error to assign null as a finalizer.
# Warning
Misuse of this API can lead to undefined behavior that is hard to debug.

# Advanced
Finalizers are not automatically called when a program exits. This is also true for
  objects that weren't reachable anymore before the program exited.
An arbitrary amount of time may pass from the $object becomes unreachable and
  the finalizer is called.
*/
add_finalizer object lambda:
  #primitive.core.add_finalizer

/**
Unregisters the finalizer registered for $object.
Returns whether the object had a finalizer.
*/
remove_finalizer object -> bool:
  #primitive.core.remove_finalizer

// Internal functions for finalizer handling.

pending_finalizers_ ::= FinalizationStack_

monitor FinalizationStack_:
  static IDLE_TIME_MS ::= 50
  lambdas_ ::= []
  task_ := null

  add lambda/Lambda -> none:
    lambdas_.add lambda
    ensure_finalization_task_

  wait_for_next -> bool:
    deadline := Time.monotonic_us + IDLE_TIME_MS * 1_000
    return try_await --deadline=deadline: not lambdas_.is_empty

  ensure_finalization_task_ -> none:
    if task_ or lambdas_.is_empty: return
    // The task code runs outside the monitor, so the monitor
    // is unlocked when the finalizers are being processed but
    // locked when the finalizers are being added and removed.
    task_ = task --name="Finalization task" --background::
      try:
        while not Task.current.is_canceled:
          if lambdas_.is_empty and not wait_for_next: break
          next := lambdas_.remove_last
          catch --trace: next.call
      finally:
        task_ = null
        ensure_finalization_task_
