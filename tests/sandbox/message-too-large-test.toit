// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// Messages are capped in size (256 KB on the host).
main args:
  sandbox-test args --error="QUOTA_EXCEEDED": | arguments/Map |
    process-send_ -1 USER-MESSAGE-TYPE (ByteArray 300_000)
