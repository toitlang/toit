// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// Flooding the system process with large messages hits the per-sender
// mailbox byte quota, so the memory a sandbox can tie up in the system
// process is bounded. The driver checks afterwards that the system process
// (and the sibling) still answer.
main args:
  sandbox-test args --error="QUOTA_EXCEEDED": | arguments/Map |
    bytes := ByteArray 200_000
    10_000.repeat: process-send_ -1 USER-MESSAGE-TYPE bytes.copy
