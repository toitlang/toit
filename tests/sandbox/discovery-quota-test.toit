// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.api.service-discovery show ServiceDiscoveryService ServiceDiscoveryServiceClient
import .sandbox

/**
A sandbox can't exhaust the memory of the system process through service
  discovery.

Registered services, pending discoveries and open clients live in the
  system process, which has no heap limit. Without limits, a sandbox grew
  the VM by about 1.5 GB in six seconds by registering services with
  100 KB names. The system process now bounds what a sandboxed process
  can register: the attack hits each limit and must get QUOTA_EXCEEDED or
  INVALID_ARGUMENT, and the system process keeps working (the driver
  checks discovery afterwards).
*/

expect-throw expected/string [block] -> none:
  exception := catch block
  if exception != expected: throw "EXPECTED $expected, GOT $exception"

main args:
  sandbox-test args --error="DONE": | arguments/Map |
    discovery := ServiceDiscoveryServiceClient
    discovery.open

    // Large strings.
    big := "x" * 10_000
    expect-throw "INVALID_ARGUMENT":
      discovery.listen 1 big --name="name" --major=1 --minor=0 --priority=0 --tags=null
    expect-throw "INVALID_ARGUMENT":
      discovery.listen 1 "uuid" --name=big --major=1 --minor=0 --priority=0 --tags=null
    expect-throw "INVALID_ARGUMENT":
      discovery.listen 1 "uuid" --name="name" --major=1 --minor=0 --priority=0 --tags=[big]
    expect-throw "INVALID_ARGUMENT":
      discovery.listen 1 "uuid" --name="name" --major=1 --minor=0 --priority=0 --tags=(List 100: "t")
    expect-throw "INVALID_ARGUMENT":
      discovery.discover big --wait

    // Registered services.
    count := 0
    exception := catch:
      1000.repeat:
        discovery.listen it "uuid-$it" --name="name" --major=1 --minor=0 --priority=0 --tags=null
        count++
    if exception != "QUOTA_EXCEEDED" or count > 16: throw "LISTEN $count $exception"
    count.repeat: discovery.unlisten it

    // Pending discoveries.
    count = 0
    exception = catch:
      1000.repeat:
        discovery.discover "uuid-$it" --wait
        count++
    if exception != "QUOTA_EXCEEDED" or count > 16: throw "DISCOVER $count $exception"

    // Open clients.
    clients := []
    exception = catch:
      1000.repeat:
        client := ServiceDiscoveryServiceClient
        client.open
        clients.add client
    if exception != "QUOTA_EXCEEDED" or clients.size > 32: throw "OPEN $clients.size $exception"
    clients.do: it.close

    // The service still works after the limits were hit.
    if (discover-pid SiblingService.SELECTOR.uuid) != arguments["sibling-pid"]: throw "WRONG_PROVIDER"
    discovery.close
    throw "DONE"
