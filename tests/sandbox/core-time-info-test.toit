// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// time_info reads the VM's time zone.
main args:
  sandbox-test args --error="PERMISSION_DENIED": | arguments/Map |
    time-info_ 0 false

time-info_ seconds/int is-utc/bool:
  #primitive.core.time-info
