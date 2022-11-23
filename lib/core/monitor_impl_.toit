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
  waiters_head_ := null
  waiters_tail_ := null
  // Queue of tasks waiting for some condition to be fulfilled.
  await_head_ := null
  await_tail_ := null

  // Yield until a condition block returns true. This should be called from a
  // locked method.  The condition is not allowed to change the state, only
  // query it.
  await [condition]:
    result := try_await_ Task_.current.deadline condition
    if not result: throw DEADLINE_EXCEEDED_ERROR

  // Yield until a condition block returns true or until a specified deadline
  // is reached. Returns true if the condition has been met or false if we have
  // reached the deadline.
  //
  // This should be called from a locked method.  The condition is not allowed
  // to change the state, only query it.
  try_await --deadline/int? [condition]:
    task_deadline := Task_.current.deadline
    if task_deadline:
      if deadline:
        deadline = min deadline task_deadline
      else:
        deadline = task_deadline

    return try_await_ deadline condition

  try_await_ deadline/int? [condition]:
    self := Task_.current
    timer/Timer_? := null
    if deadline:
      // Arrange for the notify_ method to be called if the timeout expires.
      timer = self.acquire_timer_ this

    // Unlock the monitor before the entering the loop to make the
    // state the same as it will be just after having been notified.
    if not identical self owner_: throw "must own monitor to await"
    owner_ = null

    try:
      is_non_critical ::= self.critical_count_ == 0
      first := true
      while true:
        // Check for task cancelation and timeout.
        if is_non_critical and self.is_canceled_: throw CANCELED_ERROR
        if deadline and Time.monotonic_us >= deadline: return false
        if not owner_:
          // Re-take the lock.
          owner_ = self
          // Evaluate the condition. This is usually a quick operation, but it may take time
          // and even block and the task may get canceled in the process. We need to check
          // for the timeout and cancelation notifications before blocking again, because
          // otherwise the notifications will have been lost.
          if condition.call: return true
          // Unlock the mutex while we sleep, but we are not preempted before we
          // yield, so we get the chance to resume waiters without being interrupted.
          owner_ = null
          // We assume that the state cannot change because of evaluating the
          // await condition. Without this check, we will be constantly re-evaluating
          // conditions because evaluating any condition will lead to infinite evaluations
          // of all other conditions. The state can change before the first evaluation
          // of the await condition, so we take care of that.
          resume_ --state_changed=first
          first = false
          // Check for task cancelation and timeout. We have to do this here because we may
          // have been notified while evaluating the condition in which case it would be wrong
          // to just block and wait for the next notification.
          if is_non_critical and self.is_canceled_: throw CANCELED_ERROR
          if deadline and Time.monotonic_us >= deadline: return false
        // Wait until notified. When we get back the monitor might be owned by
        // someone else.
        if timer: timer.arm deadline
        await_ self
    finally:
      if timer: self.release_timer_ timer

  locked_ [block]:
    self := Task_.current
    deadline/int? := null
    timer/Timer_? := null
    if owner_:
      deadline = self.deadline
      if deadline:
        // Arrange for the notify_ method to be called if the timeout expires.
        timer = self.acquire_timer_ this

    is_non_critical ::= self.critical_count_ == 0
    try:
      while true:
        // Check for task cancelation and timeout.
        if is_non_critical and self.is_canceled_: throw CANCELED_ERROR
        if deadline and Time.monotonic_us >= deadline: throw DEADLINE_EXCEEDED_ERROR
        // If the monitor isn't owned by anyone at this point, we are ready
        // to take it.
        if not owner_: break
        // Wait until notified. When we get back the monitor might be owned by
        // someone else.
        if timer: timer.arm deadline
        wait_ self
    finally:
      if timer: self.release_timer_ timer

    owner_ = self  // Take lock.
    try:
      block.call
    finally:
      owner_ = null
      // State may have changed as part of running the locked method.
      resume_ --state_changed
      // To guarantee some level of fairness, we yield to avoid letting
      // the calling task starve the others.
      if is_non_critical and (not identical self self.next_running_): yield

  wait_ self:
    // Add self to end of waiters list.
    tail := waiters_tail_
    if tail:
      tail.next_blocked_ = self
      waiters_tail_ = self
    else:
      waiters_head_ = waiters_tail_ = self
    suspend_ self

  await_ self:
    // Add self to end of awaiters list.
    tail := await_tail_
    if tail:
      tail.next_blocked_ = self
      await_tail_ = self
    else:
      await_head_ = await_tail_ = self
    suspend_ self

  resume_ --state_changed/bool:
    // If the state changed, we first resume the tasks waiting to
    // re-evaluate their conditions. These are tasks that have
    // already acquired the lock in the past, so it makes sense to
    // let them run first.
    waiter := await_head_
    if state_changed and waiter:
      resume_waiters_ waiter
      await_head_ = await_tail_ = null
    // Then resume the tasks waiting to run a locked method. We cannot
    // just wake the first one up, because others may have a deadline
    // that need to be evaluated.
    waiter = waiters_head_
    if waiter:
      resume_waiters_ waiter
      waiters_head_ = waiters_tail_ = null

  resume_waiters_ waiter/Task_? -> none:
    while waiter:
      waiter.resume_
      next := waiter.next_blocked_
      waiter.next_blocked_ = null
      waiter = next

  suspend_ self:
    try:
      self.monitor_ = this
      next := self.suspend_
      task_transfer_to_ next false
    finally:
      self.monitor_ = null

  // The monitor object may have been registered as the 'object notifier'
  // for a timer operation. In that case, the $notify_ method will be called
  // when the timer expires.
  notify_:
    // We resume all tasks at this point, because we don't know which ones
    // are waiting for a timeout or which ones might be canceled.
    resume_ --state_changed
