// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox
import system.api.containers show ContainerService
import system.containers

// Sandboxed clients don't discover the container service of the system
// process, and it rejects them when they open it without discovery, so
// they can't start or stop containers.
main args:
  sandbox-test args --error="PERMISSION_DENIED"
      --prepare=(:: | _ | {"ids": provider-ids ContainerService.SELECTOR.uuid}):
    | arguments/Map |
    exception := catch: containers.images
    if exception != "Cannot find service": throw "DISCOVERED: $exception"
    ids := arguments["ids"]
    open-without-discovery ids[0] ids[1] ContainerService.SELECTOR
