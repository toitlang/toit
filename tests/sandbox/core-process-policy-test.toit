// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// Querying the policy of other processes is denied.
main args:
  sandbox-test args --error="PERMISSION_DENIED": | arguments/Map |
    process-policy_ arguments["sibling-pid"]

process-policy_ pid/int:
  #primitive.core.process-policy
