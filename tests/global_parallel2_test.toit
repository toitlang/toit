// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor

global1_fun / Lambda? := null
global1 := global1_fun.call

global2_fun / Lambda? := null
global2 := global2_fun.call

global3_fun / Lambda? := null
global3 := global3_fun.call

PARALLEL_COUNT ::= 5

/**
Starts $PARALLEL_COUNT tasks in parallel.
All of the access a global variable with the $read_global lambda.
The first $fail_first tasks will throw when trying to read the global.

The $set_global_fun function should set the lambda that is associated with
  the global that is to be read. That is, $global1_fun for $global1, etc.

Also ensures that all tasks are processed in the same order they tried
  to access the global. Each tasks sets the global to a new value after
  reading (and checking) it. This also tests, that new values of the global
  are correctly read by the lazy reads.
*/
global_test --read_global/Lambda --set_global/Lambda [--set_global_fun] --fail_first/int:

  counter := 0
  all_started := false

  started := monitor.Semaphore
  set_global_fun.call::
    // We are relying on the fact that initializers never run in parallel.
    // This means that this function can decrement the semaphore counter, and
    // other tasks won't.
    if not all_started:
      PARALLEL_COUNT.repeat: started.down
      all_started = true
    current_counter := counter
    counter++
    if current_counter < fail_first: throw "try again"
    current_counter

  done := monitor.Semaphore

  PARALLEL_COUNT.repeat:
    task_id := it
    started_task := monitor.Latch
    task::
      started_task.set "started"
      if task_id < fail_first:
        expect_throw "try again": read_global.call
      else:
        // Implicitly makes sure that the order is correct.
        expect_equals task_id  read_global.call
        set_global.call (task_id + 1)
      done.up
    started_task.get
    started.up

  PARALLEL_COUNT.repeat: done.down

main:
  global_test
    --read_global=:: global1
    --set_global=:: global1 = it
    --set_global_fun=: global1_fun = it
    --fail_first=0

  global_test
    --read_global=:: global2
    --set_global=:: global2 = it
    --set_global_fun=: global2_fun = it
    --fail_first=3

  global_test
    --read_global=:: global3
    --set_global=:: global3 = it
    --set_global_fun=: global3_fun = it
    --fail_first=PARALLEL_COUNT
