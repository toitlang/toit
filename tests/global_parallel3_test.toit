// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor

global1_fun / Lambda? := null
global1 := global1_fun.call

PARALLEL_COUNT ::= 5

/**
Starts $PARALLEL_COUNT tasks in parallel.
All of the access $global1.
One of the tasks (the one with id $task_with_mutex) also takes a mutex.
Then, before the initialization has finished, we start 3 more tasks that also
  try to access the mutex.

This test checks that we don't reuse the `next_blocked_` field in the `Task_`
  class in a bad way.
*/
test task_with_mutex:
  all_started := false

  started := monitor.Semaphore
  global1_fun = ::
    // We are relying on the fact that initializers never run in parallel.
    // This means that this function can decrement the semaphore counter, and
    // other tasks won't.
    if not all_started:
      PARALLEL_COUNT.repeat: started.down
      // Give mutex task time to reach the mutex.
      20.repeat:
        yield
      all_started = true
    499

  done := monitor.Semaphore

  mutex := monitor.Mutex

  PARALLEL_COUNT.repeat:
    task_id := it
    started_task := monitor.Latch
    task::
      started_task.set "started"
      val := null
      if task_id == task_with_mutex:
        mutex.do:
          val = global1
      else:
        val = global1
      expect_equals 499 val
      done.up
    started_task.get
    started.up

  in_mutex_count := 0
  3.repeat:
    task::
      mutex.do:
        // This will have to wait for the parallel task to finish.
        in_mutex_count++

  PARALLEL_COUNT.repeat: done.down
  expect_equals 3 in_mutex_count

main:
  test 0
  test 1
  test 2
  test 3
