// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor

parallel_global := yielding
parallel_latch := monitor.Latch
yielding:
  return parallel_latch.get

main:
  NB_TASKS ::= 10
  tasks_done := monitor.Semaphore
  NB_TASKS.repeat:
    starting := monitor.Latch
    task::
      starting.set "started"
      expect_equals 499 parallel_global
      tasks_done.up
    // Wait for the task to have started.
    starting.get

  parallel_latch.set 499

  // Wait for all tasks to finish.
  NB_TASKS.repeat:
    tasks_done.down
