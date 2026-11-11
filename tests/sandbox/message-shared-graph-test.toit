// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// A shared object is encoded once per reference, so this small object
// graph (6 lists of 100 references) has an encoding of 10^12 elements.
// Computing its size in the uninterruptible process-send primitive took
// days and kept a scheduler thread (the run-time quota only kills a process
// once its primitive returns). The size pass now stops at the message-size
// quota.
main args:
  sandbox-test args --error="QUOTA_EXCEEDED": | arguments/Map |
    node/any := 7
    6.repeat:
      child := node
      node = List 100: child
    process-send_ -1 USER-MESSAGE-TYPE node
