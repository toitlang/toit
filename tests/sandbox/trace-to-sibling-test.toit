// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// Trace messages may only go to the system process.
main args:
  sandbox-test args --error="PERMISSION_DENIED": | arguments/Map |
    process-send_ arguments["sibling-pid"] SYSTEM-TRACE_ #[1, 2, 3]
