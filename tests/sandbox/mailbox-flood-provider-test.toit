// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// A sandboxed client that discovered a provider can't flood the provider's
// mailbox: the messages it has queued in another process' mailbox are capped
// (256 messages), so the provider's memory stays bounded while it is busy.
main args:
  sandbox-test args --busy-sibling-ms=3_000 --error="QUOTA_EXCEEDED": | arguments/Map |
    pid := discover-pid SiblingService.SELECTOR.uuid
    if pid != arguments["sibling-pid"]: throw "WRONG_PROVIDER"
    1000.repeat: process-send_ pid USER-MESSAGE-TYPE it
