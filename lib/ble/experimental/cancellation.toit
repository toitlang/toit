// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
Explicit cancellation points for the BLE host's procedures.

Toit delivers a task's cancellation and its deadline only at blocking
  operations. Between two atomic steps a procedure calls $checkpoint to
  observe them deterministically instead of relying on an incidental wait.
  See docs/ble/design.md, "Cancellation contract".
*/

/**
Throws CANCELED if the current task was cancelled, or DEADLINE_EXCEEDED if its
  deadline has passed; otherwise returns immediately.

Must not be called inside a `critical-do` block: critical sections defer
  cancellation by design, and the check would defeat that.
*/
checkpoint -> none:
  task := Task.current
  if task.is-canceled: throw CANCELED-ERROR
  deadline := task.deadline
  if deadline and Time.monotonic-us >= deadline: throw DEADLINE-EXCEEDED-ERROR
