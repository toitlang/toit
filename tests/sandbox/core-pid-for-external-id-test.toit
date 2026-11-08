// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// External (embedder) processes are not reachable.
main args:
  sandbox-test args --error="PERMISSION_DENIED": | arguments/Map |
    pid-for-external-id_ "toit.io/external-test"
