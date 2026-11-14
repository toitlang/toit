// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// Forging a NOTIFY-TERMINATED message (normally sent by the system process)
// is denied, also to the own process.
main args:
  sandbox-test args --error="PERMISSION_DENIED": | arguments/Map |
    process-send_ Process.current.id SYSTEM-RPC-NOTIFY-TERMINATED_ arguments["sibling-pid"]
