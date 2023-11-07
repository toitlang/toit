// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor

parallel-global := yielding
parallel-latch := monitor.Latch
yielding:
  return parallel-latch.get

main:
  NB-TASKS ::= 10
  tasks-done := monitor.Semaphore
  NB-TASKS.repeat:
    starting := monitor.Latch
    task::
      starting.set "started"
      expect-equals 499 parallel-global
      tasks-done.up
    // Wait for the task to have started.
    starting.get

  parallel-latch.set 499

  // Wait for all tasks to finish.
  NB-TASKS.repeat:
    tasks-done.down
