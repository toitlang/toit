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
  a finalizer (see $remove-finalizer).
It is also an error to assign null as a finalizer.
# Warning
Misuse of this API can lead to undefined behavior that is hard to debug.

# Advanced
Finalizers are not automatically called when a program exits. This is also true for
  objects that weren't reachable anymore before the program exited.
An arbitrary amount of time may pass from the $object becomes unreachable and
  the finalizer is called.
*/
add-finalizer object lambda -> none:
  #primitive.core.add-finalizer

make-map-weak_ map/Map -> none:
  make-weak-map_ map::
    print "Weak map callback called on $map"

make-weak-map_ map/Map lambda/Object -> none:
  #primitive.core.make-weak-map

/**
Unregisters the finalizer registered for $object.
Returns whether the object had a finalizer.
*/
remove-finalizer object -> bool:
  #primitive.core.remove-finalizer

// Internal functions for finalizer handling.

pending-finalizers_ ::= FinalizationStack_

monitor FinalizationStack_:
  static IDLE-TIME-MS ::= 50
  lambdas_ ::= []
  task_ := null

  add lambda/Lambda -> none:
    lambdas_.add lambda
    ensure-finalization-task_

  wait-for-next -> Lambda?:
    deadline := Time.monotonic-us + IDLE-TIME-MS * 1_000
    try-await --deadline=deadline: not lambdas_.is-empty
    // If we got a lambda, we must return it and deal with even if we timed out.
    return lambdas_.is-empty ? null : lambdas_.remove-last

  ensure-finalization-task_ -> none:
    if task_ or lambdas_.is-empty: return
    // The task code runs outside the monitor, so the monitor
    // is unlocked when the finalizers are being processed but
    // locked when the finalizers are being added and removed.
    task_ = task --name="Finalization task" --background::
      self ::= Task.current
      try:
        while not self.is-canceled:
          next/Lambda? := null
          if lambdas_.is-empty:
            next = wait-for-next
            if not next: break
          else:
            next = lambdas_.remove-last
          catch --trace: next.call
      finally:
        task_ = null
        ensure-finalization-task_
