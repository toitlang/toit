// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// Killing other processes is denied.
main args:
  sandbox-test args --error="PERMISSION_DENIED": | arguments/Map |
    kill_ arguments["sibling-pid"]

kill_ pid/int:
  #primitive.core.process-signal-kill
