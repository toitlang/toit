// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.containers
import .cccd-service as previous

run stage/string:
  if not ["migrate", "confirm"].contains stage: throw "INVALID_ARGUMENT"
  cycles := stage == "migrate" ? 1 : 2
  with-timeout --ms=130_000:
    groups := {}
    cycles.repeat: | cycle/int |
      provider/containers.Container? := null
      application/containers.Container? := null
      try:
        provider = previous.start "cccd-mig-host" [stage, cycle]
        application = previous.start "cccd-mig-app" [stage, cycle]
        if groups.contains provider.gid or groups.contains application.gid or provider.gid == application.gid:
          throw "CCCD_MIGRATE_GROUP_REUSED"
        groups.add provider.gid
        groups.add application.gid
        if application.wait != 0: throw "CCCD_MIGRATE_APPLICATION_EXIT"
        if provider.wait != 0: throw "CCCD_MIGRATE_PROVIDER_EXIT"
        print "CCCD_MIGRATE_SUPERVISOR CYCLE cycle=$cycle provider-gid=$(provider.gid) application-gid=$(application.gid) exits=0"
        application.close
        provider.close
      finally:
        if application:
          if not application.is-closed: application.stop
          application.close
        if provider:
          if not provider.is-closed: provider.stop
          provider.close
    print "CCCD_MIGRATE COMPLETE stage=$stage connections=$cycles groups=$(groups.size) bond-retained=true"
