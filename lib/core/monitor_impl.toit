// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

// Implementation of Monitor, see
// https://en.wikipedia.org/wiki/Monitor_(synchronization) This class is
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
    result := try_await_ task.deadline condition
    if not result: throw DEADLINE_EXCEEDED_ERROR

  // Yield until a condition block returns true or until a specified deadline
  // is reached. Returns true if the condition has been met or false if we have
  // reached the deadline.
  //
  // This should be called from a locked method.  The condition is not allowed
  // to change the state, only query it.
  try_await --deadline/int? [condition]:
    task_deadline := task.deadline
    if task_deadline:
      if deadline:
        deadline = min deadline task_deadline
      else:
        deadline = task_deadline

    return try_await_ deadline condition

  try_await_ deadline/int? [condition]:
    if deadline:
      timer := task.get_timer_
      // Arrange for the notify_ method to be called if the timeout expires.
      timer.arm this deadline

    self := task
    if not identical self owner_: throw "must own monitor to await"
    first := true
    while not condition.call:
      // Check for task cancel.
      if self.critical_count_ == 0 and self.is_canceled_: throw CANCELED_ERROR
      // Check for task timeout.
      if deadline and Time.monotonic_us >= deadline: return false
      // Unlock the mutex while we sleep, but we are not preempted before we
      // yield. If we return false above or throw a CANCELED error, we still
      // own the lock, but it will be release by the finally clause in the
      // locked_ method.
      owner_ = null
      // Let other locked methods run, but state was not changed,
      // so no need to notify_awaits, except for the first time, where the
      // locked block is left.
      notify_next_
      if first: notify_awaits_
      first = false
      await_ self    // Wait for the next notify.
      owner_ = self  // Retake the lock, ready to recheck the condition.
    return true

  locked_ [block]:
    self := task
    if owner_: wait_ self
    owner_ = self  // Take lock.
    try:
      block.call
    finally:
      owner_ = null
      notify_next_
      notify_awaits_

  // Wait for mutex to be free.
  wait_ self:
    done := false
    while not done:
      // Add self to end of waiters list.
      tail := waiters_tail_
      if tail:
        tail.next_blocked_ = self
        waiters_tail_ = self
      else:
        waiters_head_ = waiters_tail_ = self
      suspend_ self
      done = owner_ == null
    assert: owner_ == null

  // Wait for someone to notify.
  await_ self:
    done := false
    while not done:
      // Add self to end of awaiters list.
      tail := await_tail_
      if tail:
        tail.next_blocked_ = self
        await_tail_ = self
      else:
        await_head_ = await_tail_ = self
      suspend_ self
      done = owner_ == null
    assert: owner_ == null

  notify_all_:
    // If there is an owner, ignore. We'll notify all waiting once we unlock.
    if owner_: return
    notify_next_
    notify_awaits_

  // Unblock next task waiting to run locked methods.
  notify_next_:
    assert: owner_ == null
    waiter := waiters_head_
    if waiter:
      // Unlink.
      waiters_head_ = waiter.next_blocked_
      waiter.next_blocked_ = null
      if not waiters_head_: waiters_tail_ = null
      // Now resume it.
      waiter.resume_

  // Unblock all tasks waiting for a condition to be fulfilled.
  notify_awaits_:
    assert: owner_ == null
    waiter := await_head_
    if waiter:
      while waiter:
        waiter.resume_
        next := waiter.next_blocked_
        waiter.next_blocked_ = null
        waiter = next
      await_head_ = await_tail_ = null

  suspend_ self:
    task_blocked_++
    // Ensure decrement is in finally clause in case of task termination.
    try:
      self.monitor_ = this
      next := self.suspend_
      task_yield_to_ next
    finally:
      task_blocked_--
      self.monitor_ = null

  // The monitor object may have been registered as the 'object notifier'
  // for a timer operation. In that case, the $notify_ method will be called
  // when the timer expires.
  notify_:
    notify_all_
