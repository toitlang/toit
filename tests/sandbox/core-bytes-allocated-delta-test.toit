// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system
import .sandbox

// Heap statistics are not readable (like process_stats); only the GC count
// is, so a program can wait for a GC (system.gc-count).
main args:
  sandbox-test args --error="PERMISSION_DENIED": | arguments/Map |
    system.gc-count  // Allowed.
    system.bytes-allocated-delta
