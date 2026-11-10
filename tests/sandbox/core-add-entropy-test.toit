// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// Seeding the VM-wide entropy pool is denied.
main args:
  sandbox-test args --error="PERMISSION_DENIED": | arguments/Map |
    add-entropy_ #[1, 2, 3]

add-entropy_ data:
  #primitive.core.add-entropy
