// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor

global1-fun / Lambda? := null
global1 := global1-fun.call

PARALLEL-COUNT ::= 5

/**
Starts $PARALLEL-COUNT tasks in parallel.
All of the access $global1.
One of the tasks (the one with id $task-with-mutex) also takes a mutex.
Then, before the initialization has finished, we start 3 more tasks that also
  try to access the mutex.

This test checks that we don't reuse the `next_blocked_` field in the `Task_`
  class in a bad way.
*/
test task-with-mutex:
  all-started := false

  started := monitor.Semaphore
  global1-fun = ::
    // We are relying on the fact that initializers never run in parallel.
    // This means that this function can decrement the semaphore counter, and
    // other tasks won't.
    if not all-started:
      PARALLEL-COUNT.repeat: started.down
      // Give mutex task time to reach the mutex.
      20.repeat:
        yield
      all-started = true
    499

  done := monitor.Semaphore

  mutex := monitor.Mutex

  PARALLEL-COUNT.repeat:
    task-id := it
    started-task := monitor.Latch
    task::
      started-task.set "started"
      val := null
      if task-id == task-with-mutex:
        mutex.do:
          val = global1
      else:
        val = global1
      expect-equals 499 val
      done.up
    started-task.get
    started.up

  in-mutex-count := 0
  3.repeat:
    task::
      mutex.do:
        // This will have to wait for the parallel task to finish.
        in-mutex-count++

  PARALLEL-COUNT.repeat: done.down
  expect-equals 3 in-mutex-count

main:
  test 0
  test 1
  test 2
  test 3
