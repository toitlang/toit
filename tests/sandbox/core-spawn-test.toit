// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// Untrusted containers can not spawn processes.
main args:
  sandbox-test args --error="PERMISSION_DENIED": | arguments/Map |
    spawn:: print "child"
