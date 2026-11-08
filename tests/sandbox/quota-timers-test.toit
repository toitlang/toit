// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// Creating more timers than the timer quota (64) fails.
main args:
  sandbox-test args --error="QUOTA_EXCEEDED": | arguments/Map |
    timers := []
    100.repeat: timers.add Timer_
