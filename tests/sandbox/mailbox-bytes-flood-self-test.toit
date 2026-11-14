// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// Flooding a mailbox with large messages hits the mailbox byte quota.
main args:
  sandbox-test args --error="QUOTA_EXCEEDED": | arguments/Map |
    bytes := ByteArray 100_000
    100.repeat: process-send_ Process.current.id USER-MESSAGE-TYPE bytes.copy
