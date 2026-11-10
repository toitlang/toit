// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

MAILBOX-BYTES ::= 100_000

// The system process enforces the per-sender mailbox byte quota of a
// sandboxed sender, so the memory a sandbox can tie up in the system process
// is bounded. The driver checks afterwards that the system process (and the
// sibling) still answer.
//
// Whether a flood of messages that each fit the quota hits it depends on
// how fast the system process drains its mailbox (it runs concurrently), so
// the flood may or may not throw. The test asserts the bound directly: a
// message that alone exceeds the quota (but not the message size limit) is
// always refused. Accumulation at a receiver that does not drain is tested
// by mailbox-flood-provider-test.
main args:
  quotas := {"mailbox-bytes": MAILBOX-BYTES, "message-bytes": 3 * MAILBOX-BYTES}
  sandbox-test args --error="QUOTA_EXCEEDED" --quotas=quotas: | arguments/Map |
    small := ByteArray MAILBOX-BYTES / 4
    1_000.repeat: process-send_ -1 USER-MESSAGE-TYPE small.copy
    process-send_ -1 USER-MESSAGE-TYPE (ByteArray 2 * MAILBOX-BYTES)
