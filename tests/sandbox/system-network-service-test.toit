// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox
import net
import system.api.network show NetworkService

// Sandboxed clients don't discover the network service of the system
// process, and it rejects them when they open it without discovery.
main args:
  sandbox-test args --error="PERMISSION_DENIED"
      --prepare=(:: | _ | {"ids": provider-ids NetworkService.SELECTOR.uuid}):
    | arguments/Map |
    exception := catch: net.open
    if exception != "Network unavailable": throw "DISCOVERED: $exception"
    ids := arguments["ids"]
    open-without-discovery ids[0] ids[1] NetworkService.SELECTOR
