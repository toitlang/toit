// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.containers

run --resume/bool:
  with-timeout --ms=130_000:
    groups := {}
    phase := resume ? "resume" : "pair"
    2.repeat: | cycle/int |
      provider/containers.Container? := null
      application/containers.Container? := null
      try:
        resumed := resume or cycle > 0
        provider = start "cccd-provider" [resumed, cycle, phase]
        application = start "cccd-app" [cycle, resumed]
        if groups.contains provider.gid or groups.contains application.gid or
            provider.gid == application.gid:
          throw "CCCD_SERVICE_CONTAINER_GROUP_REUSED"
        groups.add provider.gid
        groups.add application.gid
        if application.wait != 0: throw "CCCD_SERVICE_APPLICATION_EXIT"
        if provider.wait != 0: throw "CCCD_SERVICE_PROVIDER_EXIT"
        print "CCCD_SERVICE_SUPERVISOR CYCLE cycle=$cycle provider-gid=$(provider.gid) application-gid=$(application.gid) exits=0"
        application.close
        provider.close
      finally:
        if application:
          if not application.is-closed: application.stop
          application.close
        if provider:
          if not provider.is-closed: provider.stop
          provider.close
    print "CCCD_SERVICE_SUPERVISOR COMPLETE groups=4 providers=2 applications=2"
    print "CCCD_PERSIST COMPLETE phase=$phase connections=2 bonds=1 retained=true"

start name/string arguments/List -> containers.Container:
  images := containers.images.filter: it.name == name
  if images.size != 1: throw "CCCD_SERVICE_IMAGE_MISSING"
  return containers.start images.first.id arguments
