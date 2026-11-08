// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// Scanning process ids: every send outside the allowed set is denied,
// also to process ids that don't exist (no probing).
main args:
  sandbox-test args --error="PERMISSION_DENIED": | arguments/Map |
    system := Process.current.id  // Own group is allowed; skip it and the system.
    denied := 0
    for pid := 0; pid < 200; pid++:
      if pid == Process.current.id or pid == SYSTEM-PROCESS-ID_: continue
      exception := catch: process-send_ pid USER-MESSAGE-TYPE [pid]
      if exception != "PERMISSION_DENIED": return
      denied++
    if denied == 198: throw "PERMISSION_DENIED"
