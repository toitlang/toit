// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import monitor
import system.containers
import expect show *

main arguments:
  // We run multiple containers from the same image (the current one),
  // so we need to distinguish between the outermost invocation and
  // the ones for the child containers.
  if arguments is Map:
    main-child arguments
    return

  test-images
  test-start
  test-background-state-changed

test-images:
  images/List := containers.images
  expect-equals 1 images.size

  // TODO(kasper): Let containers.current return a ContainerImage, so
  // we can search for that in the list of images with an appropriate
  // equality operator.
  ids/List := images.map: it.id
  expect (ids.index-of containers.current) >= 0

  writer := containers.ContainerImageWriter 4096
  writer.close

test-start:
  sub1 := containers.start containers.current {:}
  expect-equals 0 sub1.wait

  lambda2-value := null
  sub2 := containers.start containers.current {:}
      --on-stopped=:: lambda2-value = it
  expect-equals 0 sub2.wait
  expect-equals 0 lambda2-value

  lambda3-value := null
  sub3 := containers.start containers.current {:}
  expect-equals 0 sub3.wait
  // Test deprecated functionality.
  sub3.on-stopped:: lambda3-value = it  // @no-warn
  expect-equals 0 lambda3-value

  lambda4-called := false
  lambda4-value := null
  sub4 := containers.start containers.current {:}
      --on-stopped=::
        expect-not lambda4-called
        lambda4-value = it
        lambda4-called = true
  // Make sure we get the lambda called before we call
  // wait on the container. Shouldn't take too long.
  with-timeout --ms=5_000: while not lambda4-called: sleep --ms=50
  expect-equals 0 lambda4-value
  expect-equals 0 sub4.wait

test-background-state-changed:
  channel := monitor.Channel 1
  sub := containers.start containers.current { "background-state-test": true }
      --on-event=:: | event-id/int value |
        expect-equals containers.Container.EVENT-BACKGROUND-STATE-CHANGE event-id
        channel.send value

  expect-equals true channel.receive
  expect-equals false channel.receive

main-child arguments/Map:
  if arguments.contains "background-state-test":
    sleep --ms=10
    containers.notify-background-state-changed true
    containers.notify-background-state-changed false
  sleep --ms=100
