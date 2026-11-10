// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// Statistics of other processes are not readable.
main args:
  sandbox-test args --error="PERMISSION_DENIED": | arguments/Map |
    process-stats_ (Array_ 11) 0 arguments["sibling-pid"] null

process-stats_ list gid/int pid/int gc-count:
  #primitive.core.process-stats
