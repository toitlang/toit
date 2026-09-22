// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.containers

main:
  with-timeout --ms=90_000:
    children := []
    groups := {}
    try:
      children.add (start "accept-exit-p" [])
      3.repeat: children.add (start "accept-exit-a" [it])
      children.do: | child/containers.Container |
        if groups.contains child.gid: throw "CONTAINER_GROUP_REUSED"
        groups.add child.gid
      children.do: | child/containers.Container |
        if child.wait != 0: throw "ACCEPT_EXIT_CHILD_FAILED"
      print "ACCEPT_EXIT_SUPERVISOR COMPLETE groups=4 exits=0"
    finally:
      children.do: | child/containers.Container |
        if not child.is-closed: child.stop
        child.close

start name/string arguments/List -> containers.Container:
  images := containers.images.filter: it.name == name
  if images.size != 1: throw "ACCEPT_EXIT_IMAGE_MISSING"
  return containers.start images.first.id arguments
