// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// Flooding a mailbox hits the mailbox quota (256 messages).
main args:
  sandbox-test args --error="QUOTA_EXCEEDED": | arguments/Map |
    1000.repeat: process-send_ Process.current.id USER-MESSAGE-TYPE it
