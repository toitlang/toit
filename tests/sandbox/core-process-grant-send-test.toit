// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// Granting messaging capabilities is reserved for the system process.
main args:
  sandbox-test args --error="PERMISSION_DENIED": | arguments/Map |
    grant_ Process.current.id arguments["sibling-pid"]

grant_ pid/int target/int:
  #primitive.core.process-grant-send
