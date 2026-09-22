// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.containers

main:
  with-timeout --ms=60_000:
    provider := start "description-p"
    application/containers.Container? := null
    try:
      application = start "description-a"
      if provider.gid == application.gid: throw "CONTAINER_GROUP_REUSED"
      if application.wait != 0: throw "DESCRIPTION_APPLICATION_EXIT"
      if provider.wait != 0: throw "DESCRIPTION_PROVIDER_EXIT"
      print "WRITABLE_DESCRIPTION_SUPERVISOR COMPLETE groups=2 exits=0"
    finally:
      if application:
        if not application.is-closed: application.stop
        application.close
      if not provider.is-closed: provider.stop
      provider.close

start name/string -> containers.Container:
  images := containers.images.filter: it.name == name
  if images.size != 1: throw "DESCRIPTION_IMAGE_MISSING"
  return containers.start images.first.id []
