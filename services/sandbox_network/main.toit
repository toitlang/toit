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
  to sandboxed containers.

Install it as a trusted container and start it before the sandboxes that
  use it (for example as a boot container), optionally with a heap quota:

```
toit compile --snapshot -o sandbox-network.snapshot services/sandbox_network/main.toit
// Install the image with the containers service (system.containers), then:
containers.start image-id --quotas={"heap": 128 * 1024}
```

The arguments may restrict it to one variant: ["socket"] or ["http"].
*/

import .provider

main arguments:
  socket := true
  http := true
  if arguments is List and not arguments.is-empty:
    socket = arguments.contains "socket"
    http = arguments.contains "http"
  run-sandbox-network --socket=socket --http=http
