// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.containers

main:
  with-timeout --ms=80_000:
    provider := start "connectable-p"
    application/containers.Container? := null
    try:
      application = start "connectable-a"
      if provider.gid == application.gid: throw "CONTAINER_GROUP_REUSED"
      if application.wait != 0: throw "CONNECTABLE_UPDATE_APPLICATION_EXIT"
      if provider.wait != 0: throw "CONNECTABLE_UPDATE_PROVIDER_EXIT"
      print "CONNECTABLE_UPDATE_SUPERVISOR COMPLETE groups=2 exits=0"
    finally:
      if application:
        if not application.is-closed: application.stop
        application.close
      if not provider.is-closed: provider.stop
      provider.close

start name/string -> containers.Container:
  images := containers.images.filter: it.name == name
  if images.size != 1: throw "CONNECTABLE_UPDATE_IMAGE_MISSING"
  return containers.start images.first.id []
