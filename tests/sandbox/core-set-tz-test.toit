// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// The time zone is VM-global state.
main args:
  sandbox-test args --error="PERMISSION_DENIED": | arguments/Map |
    set-tz_ "UTC+5"

set-tz_ rules/string:
  #primitive.core.set-tz
