// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox
import system.storage
import system.api.storage show StorageService

// Sandboxed clients don't discover the storage service of the system
// process, and it rejects them when they open it without discovery.
main args:
  sandbox-test args --error="PERMISSION_DENIED"
      --prepare=(:: | _ | {"ids": provider-ids StorageService.SELECTOR.uuid}):
    | arguments/Map |
    exception := catch: storage.Bucket.open --ram "sandbox"
    if exception != "UNSUPPORTED": throw "DISCOVERED: $exception"
    ids := arguments["ids"]
    open-without-discovery ids[0] ids[1] StorageService.SELECTOR
