// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox
import system.containers

// The container service of the system process rejects sandboxed
// clients, so they can't start or stop containers.
main args:
  sandbox-test args --error="PERMISSION_DENIED": | arguments/Map |
    containers.images
