// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor

global1-fun / Lambda? := null
global1 := global1-fun.call

global2-fun / Lambda? := null
global2 := global2-fun.call

global3-fun / Lambda? := null
global3 := global3-fun.call

PARALLEL-COUNT ::= 5

/**
Starts $PARALLEL-COUNT tasks in parallel.
All of the access a global variable with the $read-global lambda.
The first $fail-first tasks will throw when trying to read the global.

The $set-global-fun function should set the lambda that is associated with
  the global that is to be read. That is, $global1-fun for $global1, etc.

Also ensures that all tasks are processed in the same order they tried
  to access the global. Each tasks sets the global to a new value after
  reading (and checking) it. This also tests, that new values of the global
  are correctly read by the lazy reads.
*/
global-test --read-global/Lambda --set-global/Lambda [--set-global-fun] --fail-first/int:

  counter := 0
  all-started := false

  started := monitor.Semaphore
  set-global-fun.call::
    // We are relying on the fact that initializers never run in parallel.
    // This means that this function can decrement the semaphore counter, and
    // other tasks won't.
    if not all-started:
      PARALLEL-COUNT.repeat: started.down
      all-started = true
    current-counter := counter
    counter++
    if current-counter < fail-first: throw "try again"
    current-counter

  done := monitor.Semaphore

  PARALLEL-COUNT.repeat:
    task-id := it
    started-task := monitor.Latch
    task::
      started-task.set "started"
      if task-id < fail-first:
        expect-throw "try again": read-global.call
      else:
        // Implicitly makes sure that the order is correct.
        expect-equals task-id read-global.call
        set-global.call (task-id + 1)
      done.up
    started-task.get
    started.up

  PARALLEL-COUNT.repeat: done.down

main:
  global-test
    --read-global=:: global1
    --set-global=:: global1 = it
    --set-global-fun=: global1-fun = it
    --fail-first=0

  global-test
    --read-global=:: global2
    --set-global=:: global2 = it
    --set-global-fun=: global2-fun = it
    --fail-first=3

  global-test
    --read-global=:: global3
    --set-global=:: global3 = it
    --set-global-fun=: global3-fun = it
    --fail-first=PARALLEL-COUNT
