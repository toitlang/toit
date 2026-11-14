// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// Changing the priority of a process is denied.
main args:
  sandbox-test args --error="PERMISSION_DENIED": | arguments/Map |
    set-priority_ Process.current.id 255

set-priority_ pid/int priority/int:
  #primitive.core.process-set-priority
