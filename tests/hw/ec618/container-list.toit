// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.containers

main:
  current := containers.current
  images := containers.images
  print "Current image: $current"
  print "Installed images: $images.size"
  images.do: | image/containers.ContainerImage |
    print "  id=$image.id name=$image.name flags=$image.flags data=$image.data"
  print "CONTAINER LIST PASSED"
