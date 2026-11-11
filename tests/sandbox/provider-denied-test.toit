// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.services show ServiceSelector ServiceProvider ServiceHandler
import system.api.service-discovery show ServiceDiscoveryServiceClient
import .sandbox

/**
By default a sandbox can't register service providers: the system
  process' discovery service refuses the registration with
  SERVICE_REGISTRATION_DENIED, through the provider API and through raw
  discovery calls alike. Here the sandbox tries to register a provider of
  the sibling's own service.
*/

class FakeSiblingProvider extends ServiceProvider implements ServiceHandler:
  constructor:
    super "test/sandbox/fake-sibling" --major=1 --minor=0
    provides SiblingService.SELECTOR --handler=this

  handle index/int arguments/any --gid/int --client/int -> any:
    return 0

main args:
  sandbox-test args --error="SERVICE_REGISTRATION_DENIED": | arguments/Map |
    discovery := ServiceDiscoveryServiceClient
    discovery.open
    exception := catch:
      discovery.listen 1 SiblingService.SELECTOR.uuid --name="fake" --major=1 --minor=0 --priority=0 --tags=null
    if exception != "SERVICE_REGISTRATION_DENIED": throw "RAW LISTEN: $exception"
    discovery.close
    (FakeSiblingProvider).install
