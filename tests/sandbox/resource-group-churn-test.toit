// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// core.get-generic-resource-group and timer.init malloc a resource group
// that lives until the process exits. They were not bounded, so a loop
// (whose proxies are garbage) took VM memory without bound: 64 bytes per
// call, beyond the container's heap quota. A sandboxed process now has at
// most 64 resource groups.
main args:
  sandbox-test args --error="QUOTA_EXCEEDED": | arguments/Map |
    5_000_000.repeat:
      get-generic-resource-group_
      timer-init_

get-generic-resource-group_:
  #primitive.core.get-generic-resource-group

timer-init_:
  #primitive.timer.init
