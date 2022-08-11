// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import ..system.services show ServiceManager_

// How many tasks are active.
task_count_ := 0
// How many tasks are blocked.
task_blocked_ := 0
// How many tasks are running in the background.
task_background_ := 0

// Whether the system is idle.
is_task_idle_ := false

task_resumed_ := null

exit_with_error_ := false

/**
Returns the object for the current task.

Deprecated: Use $Task.current instead.
*/
task -> Task:
  #primitive.core.task_current

/**
Creates a new user task.

Calls $code in a new task.

If the $background flag is set, then the new task will not block termination.
  The $background task flag is passed on to sub-tasks.
*/
task code/Lambda --name/string="User task" --background/bool=false -> Task:
  return create_task_ code name background

// Base API for creating and activating a task.
create_task_ code/Lambda name/string background/bool -> Task:
  new_task := task_new_ code
  new_task.name = name
  new_task.background = background or Task_.current.background
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
  task_yield_to_ Task_.current.next_running_

// ----------------------------------------------------------------------------

/**
A task.

Tasks represent a thread of running code.
Tasks are cooperative and thus must yield in order to allow other tasks to run.

Tasks are created by calling $(task code). They can either terminate by themselves
  (gracefully or with an exception) or by being canceled from the outside with
  $cancel.

If a task finishes with an exception it brings down the whole program.
*/
interface Task:
  /**
  Returns the current task.
  */
  static current -> Task:
    #primitive.core.task_current

  /**
  Cancels the task.

  If the task has `finally` clauses, those are executed.
  However, these must not yield, as the task won't run again. Use $critical_do to
  run code that must yield.
  */
  cancel -> none

  /** Whether this task is canceled. */
  is_canceled -> bool

class Task_ implements Task:
  /**
  Same as $task, but returns it as a $Task_ object instead.
  */
  static current -> Task_:
    #primitive.core.task_current

  operator == other:
    return other is Task_ and other.id_ == id_

  stringify:
    return "$name<$(id_)@$(current_process_)>"

  with_deadline_ deadline [block]:
    assert: Task_.current == this
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

  evaluate_ [code]:
    exception := null
    // Always have an outer catch clause. Without this, a throw will crash the VM.
    // In that, we have an inner, but very pretty, root exception handling.
    // This can fail in rare cases where --trace will OOM, kernel reject the message, etc.
    try:
      exception = catch --trace code
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
      // Check whether no service definitions and only background tasks are running.
      if ServiceManager_.is_empty and task_count_ == task_background_: __halt__
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
    current /Task_? := ?
    if is_task_idle_:
      current = task_resumed_
      if not current:
        task_resumed_ = this
        return
    else:
      current = Task_.current

    // Link the task into the linked list of running tasks
    // at the very end of it.
    previous := current.previous_running_
    current.previous_running_ = this
    previous.next_running_ = this
    previous_running_ = previous
    next_running_ = current

  // Acquiring a timer will reuse the first previously released timer if
  // available. We use a single element cache to avoid creating timer objects
  // repeatedly when it isn't necessary.
  acquire_timer_ monitor/__Monitor__ -> Timer_:
    timer := timer_
    if timer:
      timer_ = null
    else:
      timer = Timer_
    timer.set_target monitor
    return timer

  // Releasing a timer will make it available for reuse or close it if the
  // single element cache is already filled.
  release_timer_ timer/Timer_:
    existing := timer_
    if existing:
      timer.close
    else:
      timer.clear_target
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

  // Timer used for all sleep operations on this task.
  timer_ := null

  name := null

  background := null

// ----------------------------------------------------------------------------

task_new_ lambda/Lambda -> Task_:
  #primitive.core.task_new

task_transfer_ to/Task_ detach_stack:
  #primitive.core.task_transfer

task_yield_to_ to/Task_:
  if Task_.current != to:   // Skip self transfer.
    task_transfer_ to false

  // TODO(kasper): Consider not looking at the incoming messages at
  // all yield points. Maybe only once per run through the runnable tasks?

  // Messages must be processed after returning to a running task,
  // not before transfering away from a suspended one.
  process_messages_
