// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox
import system.containers

// A process that runs longer than its run-time limit without returning to
// the scheduler is killed by the VM (instead of the dead-lock FATAL that
// trusted processes get on devices). Here the limit is shorter than the
// scheduler tick, so the spinning process is killed at the next tick.
main args:
  sandbox-test args --exit=containers.EXIT-CPU-BUDGET --quotas={"run-time-ms": 20}: | arguments/Map |
    while true: null
