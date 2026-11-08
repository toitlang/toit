// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// The real-time clock of the device is not writable.
main args:
  sandbox-test args --error="PERMISSION_DENIED": | arguments/Map |
    set-rtc_ 0 0

set-rtc_ seconds/int ns/int:
  #primitive.core.set-real-time-clock
