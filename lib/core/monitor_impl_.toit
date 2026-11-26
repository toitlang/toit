// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

// Implementation of Monitor, see
// https://en.wikipedia.org/wiki/Monitor_(synchronization). This class is
// special, in that if you use the 'monitor' keyword instead of the 'class'
// method, then your class inherits from this class, and all public methods are
// wrapped in a locked: call. Since the lock is not reentrant this means
// there will be a deadlock if you call a public method from a different public
// method.
class __Monitor__:
  // When owner_ is set, the mutex is taken.  Because there is no preemption within
  // tasks we don't need a primitive to take the mutex.
  owner_ := null
  // Queue of tasks waiting to take the mutex and run locked methods.
  waiters-head_ := null
  waiters-tail_ := null
  // Queue of tasks waiting for some condition to be fulfilled.
  await-head_ := null
  await-tail_ := null

  /**
  Yields until the $condition block returns true.
  This should be called from a  locked method.
  The condition is not allowed to change the state, only query it.

  The monitor is released while waiting. It is owned again when this method
    returns or throws, also after a timeout or a cancelation, which might have
    to wait for another task to leave the monitor.
  */
  await [condition]:
    result := try-await_ Task_.current.deadline condition
    if not result: throw DEADLINE-EXCEEDED-ERROR

  /**
  Yields until the $condition block returns true or until the given $deadline
    is reached.

  Returns true if the condition has been met or false if we have
    reached the deadline.

  This should be called from a locked method.
  The condition is not allowed to change the state, only query it.

  The monitor is released while waiting. It is owned again when this method
    returns or throws, also after a timeout or a cancelation, which might have
    to wait for another task to leave the monitor.
  */
  try-await --deadline/int? [condition]:
    task-deadline := Task_.current.deadline
    if task-deadline:
      if deadline:
        deadline = min deadline task-deadline
      else:
        deadline = task-deadline

    return try-await_ deadline condition

  try-await_ deadline/int? [condition]:
    self := Task_.current
    timer/Timer_? := null
    if deadline:
      // Arrange for the notify_ method to be called if the timeout expires.
      timer = self.acquire-timer_ this

    // Unlock the monitor before the entering the loop to make the
    // state the same as it will be just after having been notified.
    if not identical self owner_: throw "must own monitor to await"
    owner_ = null

    // The loop ends with `break`, not `return`, so the try block completes
    // without a non-local return through the finally code.
    result := false
    try:
      is-non-critical ::= self.critical-count_ == 0
      first := true
      while true:
        // Check for task cancelation and timeout.
        if is-non-critical and self.is-canceled_: throw CANCELED-ERROR
        if deadline and Time.monotonic-us >= deadline: break
        if not owner_:
          // Re-take the lock.
          owner_ = self
          // Evaluate the condition. This is usually a quick operation, but it may take time
          // and even block and the task may get canceled in the process. We need to check
          // for the timeout and cancelation notifications before blocking again, because
          // otherwise the notifications will have been lost.
          if condition.call:
            result = true
            break
          // Unlock the mutex while we sleep, but we are not preempted before we
          // yield, so we get the chance to resume waiters without being interrupted.
          owner_ = null
          // We assume that the state cannot change because of evaluating the
          // await condition. Without this check, we will be constantly re-evaluating
          // conditions because evaluating any condition will lead to infinite evaluations
          // of all other conditions. The state can change before the first evaluation
          // of the await condition, so we take care of that.
          resume_ --state-changed=first
          first = false
          // Check for task cancelation and timeout. We have to do this here because we may
          // have been notified while evaluating the condition in which case it would be wrong
          // to just block and wait for the next notification.
          if is-non-critical and self.is-canceled_: throw CANCELED-ERROR
          if deadline and Time.monotonic-us >= deadline: break
        // Wait until notified. When we get back the monitor might be owned by
        // someone else.
        if timer: timer.arm deadline
        await_ self
    finally:
      if timer: self.release-timer_ timer
      // After a timeout or a cancelation we don't own the monitor, and another
      // task might. The rest of the locked method must run with the monitor,
      // and locked_ releases it when the method ends, so we take it back.
      // We can't leave without it, so we wait for it without a deadline and
      // without checking for cancelation. The task stays canceled.
      while not identical self owner_:
        if owner_:
          wait_ self
        else:
          owner_ = self
    return result

  locked_ [block]:
    self := Task_.current
    deadline/int? := null
    timer/Timer_? := null
    if owner_:
      deadline = self.deadline
      if deadline:
        // Arrange for the notify_ method to be called if the timeout expires.
        timer = self.acquire-timer_ this

    is-non-critical ::= self.critical-count_ == 0
    if not owner_:
      // Not owned: the loop below would only check for cancelation (there
      // is no deadline and no timer), so it needs no try.
      if is-non-critical and self.is-canceled_: throw CANCELED-ERROR
    else:
      try:
        while true:
          // Check for task cancelation and timeout.
          if is-non-critical and self.is-canceled_: throw CANCELED-ERROR
          if deadline and Time.monotonic-us >= deadline: throw DEADLINE-EXCEEDED-ERROR
          // If the monitor isn't owned by anyone at this point, we are ready
          // to take it.
          if not owner_: break
          // Wait until notified. When we get back the monitor might be owned by
          // someone else.
          if timer: timer.arm deadline
          wait_ self
      finally:
        if timer: self.release-timer_ timer

    // The block's value is the monitor method's result (the compiler turns
    // the method's returns into exits of the block, see monitor.cc): kept
    // in a local so that the try block completes without a non-local
    // return.
    result := null
    try:
      // The lock is taken inside the try, so the finally code always
      // releases it: on the verified core, entering the try can fail (out
      // of memory or a stack overflow when the stack can't grow for the
      // try's block) before the finally code is installed. Taken before,
      // the lock would stay taken and the next locked method would wait
      // for it forever. Nothing between the check above and here yields.
      owner_ = self  // Take lock.
      result = block.call
    finally:
      owner_ = null
      // State may have changed as part of running the locked method.
      resume_ --state-changed
      // To guarantee some level of fairness, we yield to avoid letting
      // the calling task starve the others.
      if is-non-critical and (not identical self self.next-running_ or task-has-messages_):
        yield
    return result

  wait_ self:
    // Add self to end of waiters list.
    tail := waiters-tail_
    if tail:
      tail.next-blocked_ = self
      waiters-tail_ = self
    else:
      waiters-head_ = waiters-tail_ = self
    suspend_ self

  await_ self:
    // Add self to end of awaiters list.
    tail := await-tail_
    if tail:
      tail.next-blocked_ = self
      await-tail_ = self
    else:
      await-head_ = await-tail_ = self
    suspend_ self

  resume_ --state-changed/bool:
    // If the state changed, we first resume the tasks waiting to
    // re-evaluate their conditions. These are tasks that have
    // already acquired the lock in the past, so it makes sense to
    // let them run first.
    waiter := await-head_
    if state-changed and waiter:
      resume-waiters_ waiter
      await-head_ = await-tail_ = null
    // Then resume the tasks waiting to run a locked method. We cannot
    // just wake the first one up, because others may have a deadline
    // that need to be evaluated.
    waiter = waiters-head_
    if waiter:
      resume-waiters_ waiter
      waiters-head_ = waiters-tail_ = null

  resume-waiters_ waiter/Task_? -> none:
    while waiter:
      waiter.resume_
      next := waiter.next-blocked_
      waiter.next-blocked_ = null
      waiter = next

  suspend_ self:
    try:
      self.monitor_ = this
      self.suspend_
    finally:
      self.monitor_ = null

  // The monitor object may have been registered as the 'object notifier'
  // for a timer operation. In that case, the $notify_ method will be called
  // when the timer expires.
  notify_:
    // We resume all tasks at this point, because we don't know which ones
    // are waiting for a timeout or which ones might be canceled.
    resume_ --state-changed
