// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.containers
import expect show *

main:
  images/List := containers.images
  expect_equals 1 images.size

  // TODO(kasper): Let containers.current return a ContainerImage, so
  // we can search for that in the list of images with an appropriate
  // equality operator.
  ids/List := images.map: it.id
  expect (ids.index_of containers.current) >= 0

  writer := containers.ContainerImageWriter 4096
  writer.close
