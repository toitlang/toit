// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// timer.init mallocs a resource group that lives until the process exits.
// It was not bounded, so a loop (whose proxies are garbage) took VM memory
// without bound: 64 bytes per call, beyond the container's heap quota. A
// sandboxed process now has at most 64 resource groups.
// core.get-generic-resource-group had the same problem; it is no longer in
// the untrusted set (core-get-generic-resource-group-test).
main args:
  sandbox-test args --error="QUOTA_EXCEEDED": | arguments/Map |
    5_000_000.repeat:
      timer-init_

timer-init_:
  #primitive.timer.init
