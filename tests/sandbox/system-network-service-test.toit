// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox
import net

// The network service of the system process rejects sandboxed clients.
main args:
  sandbox-test args --error="PERMISSION_DENIED": | arguments/Map |
    net.open
