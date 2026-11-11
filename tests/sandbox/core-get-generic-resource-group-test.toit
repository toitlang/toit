// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// Resource groups of the core module are only used by modules the policy
// denies (crypto, zlib, flash, rmt, ...).
main args:
  sandbox-test args --error="PERMISSION_DENIED": | arguments/Map |
    get-generic-resource-group_

get-generic-resource-group_:
  #primitive.core.get-generic-resource-group
