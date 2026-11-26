// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

/**
The sandbox network provider (experimental): an installable program that
  offers the sandbox socket and HTTP services (system.api.sandbox-network)
  to sandboxed containers. It is not part of the firmware: install it, as a
  trusted container, only on devices that run sandboxes that need the
  network.

Its network policy applies to every sandboxed client (the limits are kept
  per client container): "all", "public", a list of rules
  (`["api.example.com:443"]`), or a map of rules and limits
  (`{"allow": [...], "bytes-per-day": 1000000}`; see `network-policy-list`
  in the system.api.sandbox-network library). Without a policy it allows
  nothing. The policy comes from the container's arguments, a map with the
  key "network" (and optionally "services": ["socket"] or ["http"]), or,
  for a container installed in the firmware envelope (which starts without
  arguments), from its asset "network" (JSON):

```
toit compile --snapshot -o sandbox-network.snapshot services/sandbox_network/main.toit
echo '"public"' > network.json
toit tool assets -e sandbox-network.assets create
toit tool assets -e sandbox-network.assets add --format=tison network network.json
toit tool firmware -e firmware.envelope container install \
    --assets=sandbox-network.assets sandbox-network sandbox-network.snapshot
```

or from a trusted program, with a heap quota:

```
containers.start provider-image-id {"network": "public"} --quotas={"heap": 128 * 1024}
```

Sandboxes then use it when they may use its services:
  `containers.start id --untrusted --services="all"` (or the two service
  uuids, `SandboxSocketService.SELECTOR` and `SandboxHttpService.SELECTOR`).
*/

import encoding.json
import system.assets

import .provider

main arguments:
  config := arguments is Map ? arguments : {:}
  network := config.get "network" --if-absent=: asset-network_
  services := config.get "services" --if-absent=: ["socket", "http"]
  run-sandbox-network --network=network
      --socket=(services.contains "socket")
      --http=(services.contains "http")

// The policy in the container's assets, if any.
asset-network_ -> any:
  catch:
    value := assets.decode.get "network"
    if value is ByteArray: return json.decode value
    return value
  return null
