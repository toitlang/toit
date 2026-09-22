// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import system.containers
import .vhci-service-multipeer as fixture

main arguments:
  if arguments is Map:
    with-timeout --ms=60_000:
      if arguments.get "provider":
        if arguments.contains "index":
          fixture.application arguments
        else:
          print "SERVICE_RESTART PROVIDER cycle=$(arguments["cycle"]) pid=$(Process.current.id)"
          fixture.run
      else:
        throw "INVALID_FIXTURE_ARGUMENTS"
    return
  with-timeout --ms=180_000:
    groups := {}
    3.repeat: | cycle/int |
      child := containers.start containers.current {"provider": true, "cycle": cycle}
      try:
        if groups.contains child.gid: throw "PROVIDER_GROUP_REUSED"
        groups.add child.gid
        if child.wait != 0: throw "PROVIDER_CYCLE_FAILED"
        print "SERVICE_RESTART CYCLE cycle=$cycle group=$(child.gid) exit=0"
      finally:
        child.close
    print "SERVICE_RESTART COMPLETE providers=3 clients=6 reads=732"
