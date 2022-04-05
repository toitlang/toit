// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.containers
import expect show *

main:
  images/List := containers.images
  expect_list_equals [containers.current] images

  writer := containers.ContainerImageWriter 4096
  writer.close
