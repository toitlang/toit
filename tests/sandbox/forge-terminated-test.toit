// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// Forging a TERMINATED system message to the system process is denied.
main args:
  sandbox-test args --error="PERMISSION_DENIED": | arguments/Map |
    process-send_ -1 SYSTEM-TERMINATED_ 0
