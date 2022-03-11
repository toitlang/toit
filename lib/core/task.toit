// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

// How many tasks are active.
task_count_ := 0
// How many tasks are blocked.
task_blocked_ := 0
// How many tasks are running in the background.
task_background_ := 0

// Whether the system is idle.
is_task_idle_ := false

is_processing_messages_ := false

task_resumed_ := null

exit_with_error_ := false

/**
Returns the object for the current task.
*/
task:
  #primitive.core.task_current

/**
Creates a new user task.

Calls $code in a new task.

If the $background flag is set, then the new task will not block termination.
  The $background task flag is passed on to sub-tasks.
*/
task code --background/bool=false :
  return create_task_ "User task" code --background=background

// Base API for creating and activating a task.
create_task_ name code --background/bool=false:
  new_task := task_new_:: task.evaluate_ code
  new_task.name = name
  new_task.background = background or task.background
  new_task.initialize_
  // Activate the new task.
  new_task.previous_running_ = new_task.next_running_ = new_task
  new_task.resume_
  return new_task

/**
Voluntarily yields control of the CPU to other tasks.

# Advanced
The Toit programming language is cooperatively scheduled, so it is important
  to place yields in long running loops if other tasks should get an
  opportunity to run.
*/
yield:
  task_yield_to_ task.next_running_

// Helper method to mark the stack where user code starts.
_USER_BOUNDARY_ lambda:
  return lambda.call

// ----------------------------------------------------------------------------

class Task_:
  operator == other:
    return other is Task_ and other.id_ == id_

  stringify:
    return "$name<$(id_)@$(current_process_)>"

  with_deadline_ deadline [block]:
    assert: task == this
    if not deadline_ or deadline < deadline_:
      old_deadline := deadline_
      deadline_ = deadline
      try:
        return block.call old_deadline
      finally:
        deadline_ = old_deadline
    else:
      return block.call deadline_

  deadline: return deadline_

  // Mark the task for cancellation, at the next idle operation.
  cancel:
    is_canceled_ = true
    if monitor_ and critical_count_ == 0: monitor_.notify_

  is_canceled -> bool: return is_canceled_

  id: return id_

  initialize_:
    is_canceled_ = false
    critical_count_ = 0
    task_count_++
    if background: task_background_++

  // Configures the main task. Called by __entry__
  initialize_entry_task_:
    assert: task_count_ == 0
    name = "Main task"
    initialize_
    previous_running_ = next_running_ = this
    // Create new system task without finalization behavior.
    system_task_ = create_task_ "System task" --background::(SystemState_).run_finalizers

  evaluate_ code:
    exception := null
    // Always have an outer catch clause. Without this, a throw will crash the VM.
    // In that, we have an inner, but very pretty, root exception handling.
    // This can fail in rare cases where --trace will OOM, kernel reject the message, etc.
    try:
      exception = catch --trace:
        _USER_BOUNDARY_ code
    finally: | is_exception trace_exception |
      // If we got an exception here, either
      // 1) the catch failed to guard against the exception so we assume
      //    nothing works and just print the error.
      // 2) the task was canceled.
      if is_exception:
        exception = trace_exception.value
        if exception == CANCELED_ERROR and is_canceled:
          exception = null
        else:
          print_ exception
      exit_ exception != null

  exit_ has_error/bool:
    if has_error: exit_with_error_ = true
    task_count_--
    if background: task_background_--
    // Yield to the next task.
    next := suspend_
    if timer_:
      timer_.close
      timer_ = null
    task_transfer_ next true  // Passing null will detach the calling execution stack from the task.

  suspend_:
    previous := previous_running_
    if previous == this:
      // If we encounted a root-error, terminate the process.
      if exit_with_error_: __exit__ 1
      // Check whether only background tasks are running.
      if task_count_ == task_background_: __halt__
      is_task_idle_ = true
      while true:
        process_messages_
        resumed := task_resumed_
        if resumed:
          is_task_idle_ = false
          task_resumed_ = null
          return resumed
        __yield__
    else:
      // Unlink from the linked of running tasks.
      next := next_running_
      previous.next_running_ = next
      next.previous_running_ = previous
      next_running_ = previous_running_ = this
      return next

  resume_ -> none:
    current := null
    if is_task_idle_:
      current = task_resumed_
      if not current:
        task_resumed_ = this
        return
    else:
      current = task

    // Link the task into the linked list of running tasks
    // at the very end of it.
    previous := current.previous_running_
    current.previous_running_ = this
    previous.next_running_ = this
    previous_running_ = previous
    next_running_ = current

  with_timer_ [block]:
    timer := acquire_timer_
    try:
      block.call timer
    finally:
      release_timer_ timer

  acquire_timer_ -> Timer_:
    timer := timer_
    if timer:
      timer_ = null
      return timer
    return Timer_

  release_timer_ timer/Timer_:
    existing := timer_
    if existing:
      timer.close
    else:
      timer_ = timer

  // Task state initialized by the VM.
  id_ := null

  // Deadline and cancel support.
  deadline_ := null
  is_canceled_ := null
  critical_count_ := null

  // If the task is blocked in a monitor, this reference that monitor.
  monitor_ := null

  // All running tasks are chained together in linked list.
  next_running_ := null
  previous_running_ := null
  next_blocked_ := null

  // TODO(kasper): Generalize this a bit. It is only used
  // for implementing generators for now.
  tls := null

  // Timer used for all sleep operations on this task.
  timer_ := null

  name := null

  background := null

// ----------------------------------------------------------------------------

task_new_ lambda:
  #primitive.core.task_new

task_entry_ code:
  // The entry stack setup is a bit complicated, so when we
  // transfer to a task stack for the first time, the
  // `task transfer` primitive will provide a value for us
  // on the stack. The `null` assigned to `fake` below is
  // skipped and we let the value passed to us take its place.
  life := null
  assert: life == 42
  code.call
  throw "Should not get here"

task_transfer_ to detach_stack:
  #primitive.core.task_transfer

task_yield_to_ to:
  if task != to:   // Skip self transfer.
    task_transfer_ to false

  // TODO(kasper): Consider not looking at the incoming messages at
  // all yield points. Maybe only once per run through the runnable tasks?

  // Messages must be processed after returning to a running task,
  // not before transfering away from a suspended one.
  process_messages_

system_task_ := null

// Execute all finalizers. The call next_finalizer_to_run_
// returns null when there are no finalizers to run.
monitor SystemState_:
  constructor:
    set_finalizer_notifier_ this

  run_finalizers:
    while true:
      lambda := null
      await: lambda = next_finalizer_to_run_
      catch --trace: lambda.call


// Primitives to support the task implementation.

current_process_:
  #primitive.core.current_process_id
