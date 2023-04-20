// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import monitor
import ..system.services show ServiceManager_

// How many tasks are alive?
task_count_ := 0
// How many tasks are alive, but running in the background?
task_background_ := 0

/**
Returns the object for the current task.

Deprecated: Use $Task.current instead.
*/
task -> Task:
  return Task_.current

/**
Creates a new user task.

Calls $code in a new task.

If the $background flag is set, then the new task will not block termination.
  The $background task flag is passed on to sub-tasks.
*/
task code/Lambda --name/string="User task" --background/bool?=null -> Task:
  if background == null: background = Task_.current.background
  return create_task_ code name background

// Base API for creating and activating a task.
create_task_ code/Lambda name/string background/bool -> Task:
  new_task := task_new_ code
  new_task.name_ = name
  new_task.background_ = background
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
  process_messages_
  task_transfer_to_ Task_.current.next_running_ false

// ----------------------------------------------------------------------------

/**
A task.

Tasks represent a thread of running code.
Tasks are cooperative and thus must yield in order to allow other tasks to run.

Tasks are created by calling $(task code). They can either terminate by themselves
  (gracefully or with an exception) or by being canceled from the outside with
  $cancel.

See more on tasks at https://docs.toit.io/language/tasks.

If a task finishes with an exception it brings down the whole program.
*/
interface Task:
  /**
  Returns the current task.
  */
  static current -> Task:
    return Task_.current

  /**
  Runs the given $lambdas as a group of concurrent tasks.

  Returns the results of running the $lambdas as a $Map
    keyed by the lambda index. If the lambda at a given
    index did not return, the results map will not contain
    and entry for it. The results map is insertion ordered,
    so it is possible to tell which lambda returned first.

  If any of the $lambdas throws an exception, the exception is
    propagated to the caller of $Task.group which in
    return also throws.

  If $required is less than the number of $lambdas, the
    method returns when $required tasks have completed.
  */
  static group lambdas/List -> Map
      --required/int=lambdas.size:
    count ::= lambdas.size
    tasks ::= Array_ count
    results ::= {:}
    if count < 2 or not (1 <= required <= count):
      throw "Bad Argument"

    is_stopping/bool := false
    is_canceled/bool := false
    caught/Exception_? := null

    terminated := 0
    signal ::= monitor.Signal
    for index := 0; index < count; index++:
      tasks[index] = task::
        while true:
          try:
            results[index] = lambdas[index].call
          finally: | is_exception exception |
            if Task.current.is_canceled:
              // If we get canceled after we decided to stop, we
              // avoid propagating the cancelation to the task
              // that invoked Task.group.
              if not is_stopping:
                is_canceled = true
                is_stopping = true
            else if is_exception:
              // We prefer the first exception and that is the
              // one we propagate to the caller of Task.group.
              if not caught: caught = exception
              is_stopping = true
            tasks[index] = null
            terminated++
            critical_do: signal.raise
            break  // Stop the unwinding.

      // We prefer giving the new tasks a chance to run eagerly,
      // so we yield here to start it up. In return, this makes
      // it possible that we get stopped before creating all the
      // tasks, so we deal with that by leaving the loop.
      yield
      if is_stopping:
        // Count remaining tasks as eagerly terminated.
        terminated += count - index - 1
        break

    try:
      signal.wait: is_stopping or terminated >= required
    finally:
      if terminated < count:
        // We're either stopping or we got the required results.
        // Make sure we're marked as stopping and cancel all
        // the tasks that are still live.
        is_stopping = true
        tasks.do: if it: it.cancel
        // Wait until all tasks have terminated.
        critical_do --no-respect_deadline:
          // TODO(kasper): Consider letting the user control the timeout.
          with_timeout --ms=1_000: signal.wait: terminated == count

    if caught:
      rethrow caught.value caught.trace
    else if is_canceled:
      Task.current.cancel
    return results

  /**
  Cancels the task.

  If the task has `finally` clauses, those are executed.
  However, these must not yield, as the task won't run again. Use $critical_do to
  run code that must yield.
  */
  cancel -> none

  /** Whether this task is canceled. */
  is_canceled -> bool

  /**
  Returns the deadline for the task as a microsecond timestamp that can be
    compared against return values from $Time.monotonic_us.

  Returns null if the task has no deadline.
  */
  deadline -> int?

class Task_ implements Task:
  /**
  Same as $Task.current, but returns it as a $Task_ object instead.
  */
  static current/Task_? := null

  background -> bool:
    return background_

  operator == other:
    return other is Task_ and other.id_ == id_

  stringify:
    return "$name_<$(id_)@$(Process.current.id)>"

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
  cancel -> none:
    is_canceled_ = true
    if monitor_ and critical_count_ == 0: monitor_.notify_

  is_canceled -> bool: return is_canceled_

  id: return id_

  initialize_:
    is_canceled_ = false
    critical_count_ = 0
    state_ = STATE_SUSPENDED
    task_count_++
    if background_: task_background_++

  // Configures the main task. Called by __entry__main and __entry__spawn.
  initialize_entry_task_:
    assert: task_count_ == 0
    name_ = "Main task"
    background_ = false
    initialize_
    state_ = STATE_RUNNING
    previous_running_ = next_running_ = this

  evaluate_ [code] -> none:
    try:
      evaluate_and_trace_ code

      // Process messages now. We do this before we determine
      // if the process is done to allow new tasks to spin
      // up as part of the processing and impact the decision.
      evaluate_and_trace_: process_messages_

      // If no services are defined and only background tasks are
      // alive at this point, we terminate the process gracefully.
      task_count := task_count_ - 1
      task_background := task_background_
      if background_: task_background--
      if task_count == task_background and ServiceManager_.is_empty:
        __exit__ 0

      // We still have tasks left, so we need to update the counts
      // and process messages until some other running task can
      // take that responsibility over.
      task_count_ = task_count
      task_background_ = task_background
      while identical this previous_running_:
        __yield__
        evaluate_and_trace_: process_messages_

      // Mark this task as terminated and unlink it from the
      // list of running tasks.
      state_ = STATE_TERMINATED
      next := unlink_
      task_transfer_to_ next true  // Never returns.

    finally:
      __exit__ 1

  /**
  Evaluates the $block and safely traces any exceptions.

  If evaluating the $block causes an exception, we let
    the unwinding continue, unless it is due to
    cancelation.
  */
  evaluate_and_trace_ [block] -> none:
    traced := false
    try:
      catch block
          --trace=:
            true
          --unwind=:
            // The --trace block is invoked before
            // the --unwind block, so we only get
            // here if tracing did not cause an
            // exception itself.
            traced = true
            true
    finally: | is_exception exception |
      // Release any acquired timer resource. We
      // probably do not need it going forward and
      // it will be re-acquired on demand.
      timer := timer_
      if timer:
        timer.close
        timer_ = null
      // Check if we need to consume any cancelation
      // errors and try to print a helpful message
      // if we failed to trace the exception in the
      // first attemp.
      if is_exception:
        value := exception.value
        if is_canceled_ and value == CANCELED_ERROR:
          return
        else if not traced:
          write_on_stdout_ "Uncaught exception: " false
          print_ value

  suspend_:
    state_ = STATE_SUSPENDING
    while true:
      process_messages_
      // Check if we got resumed through the message processing.
      if state_ == STATE_RUNNING: return this
      // If this task not the only task left, we unlink it from
      // the linked list of running tasks and mark it suspended.
      if not identical this previous_running_:
        state_ = STATE_SUSPENDED
        return unlink_
      // This task is the only task left. We keep it in the
      // suspending state and tell the system to wake us up when
      // new messages arrive.
      __yield__

  resume_ -> none:
    // Link the task into the linked list of running tasks
    // at the very end of it.
    if state_ == STATE_SUSPENDED:
      current ::= Task_.current
      previous := current.previous_running_
      current.previous_running_ = this
      previous.next_running_ = this
      previous_running_ = previous
      next_running_ = current
    state_ = STATE_RUNNING

  unlink_:
    assert: not identical this previous_running_
    next := next_running_
    previous := previous_running_
    previous.next_running_ = next
    next.previous_running_ = previous
    next_running_ = previous_running_ = this
    return next

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

  // Task state initialized by Toit code.
  name_ := null
  background_ := null

  // Deadline and cancelation support.
  deadline_ := null
  is_canceled_ := null
  critical_count_ := null

  // If the task is blocked in a monitor, this reference that monitor.
  monitor_ := null

  // All running tasks are chained together in a doubly linked list.
  next_running_ := null
  previous_running_ := null

  // Waiting tasks are chained together in a singly linked list.
  next_blocked_ := null

  // Timer used for all sleep operations on this task.
  timer_ := null

  static STATE_RUNNING    /int ::= 0
  static STATE_SUSPENDING /int ::= 1
  static STATE_SUSPENDED  /int ::= 2
  static STATE_TERMINATED /int ::= 3
  state_ := null  // TODO(kasper): Document this.

// ----------------------------------------------------------------------------

task_new_ lambda/Lambda -> Task_:
  #primitive.core.task_new

task_transfer_to_ to/Task_ detach_stack:
  #primitive.core.task_transfer: | task |
    Task_.current = task
    return task
