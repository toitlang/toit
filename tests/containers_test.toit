// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.containers
import expect show *

main arguments:
  // We run multiple containers from the same image (the current one),
  // so we need to distinguish between the outermost invocation and
  // the ones for the child containers.
  if arguments is Map:
    main_child arguments
    return

  test_images
  test_start

test_images:
  images/List := containers.images
  expect_equals 1 images.size

  // TODO(kasper): Let containers.current return a ContainerImage, so
  // we can search for that in the list of images with an appropriate
  // equality operator.
  ids/List := images.map: it.id
  expect (ids.index_of containers.current) >= 0

  writer := containers.ContainerImageWriter 4096
  writer.close

test_start:
  sub1 := containers.start containers.current {:}
  expect_equals 0 sub1.wait

  lambda2_value := null
  sub2 := containers.start containers.current {:}
  sub2.on_stopped:: lambda2_value = it
  expect_equals 0 sub2.wait
  expect_equals 0 lambda2_value

  lambda3_value := null
  sub3 := containers.start containers.current {:}
  expect_equals 0 sub3.wait
  sub3.on_stopped:: lambda3_value = it
  expect_equals 0 lambda3_value

  lambda4_value := null
  sub4 := containers.start containers.current {:}
  sleep --ms=200
  sub4.on_stopped:: lambda4_value = it
  expect_equals 0 lambda4_value
  expect_equals 0 sub4.wait

main_child arguments/Map:
  sleep --ms=100
