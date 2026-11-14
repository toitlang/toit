// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import uuid
import system.api.containers show ContainerService

import ..system.containers
import ..system.flash.registry
import ..system.services

// This test supplies its own system services and needs privileged registry
// access. Run with toit.run -b none, as selected by the test's filename.
main:
  discovery := SystemServiceManager
  manager := ContainerManager FlashRegistry.scan discovery
  system-image := TestImage manager "00000000-0000-0000-0000-000000000001"
  app := TestImage manager "00000000-0000-0000-0000-000000000002"
  manager.register-system-image system-image
  manager.register-image app
  system-image.load.start
  running := app.load
  running.start
  loaded := app.load  // A not-yet-started handle must not crash shutdown.
  try:
    manager.shutdown
    expect-equals 0 system-image.stops
    expect-equals 1 app.stops
    // Late termination notifications from a critical image must not abort
    // the system process while its remaining cleanup is still running.
    running.on-process-stop_ running.id 1
    expect-throw "System is shutting down": app.load
    expect-throw "System is shutting down": loaded.start
    expect-throw "System is shutting down":
      manager.handle ContainerService.LIST-IMAGES-INDEX null --gid=0 --client=0
    // Stopping applications during shutdown must not wake boot's main
    // task and exit the system process before its services are closed.
    expect-throw DEADLINE-EXCEEDED-ERROR:
      with-timeout --ms=10: manager.wait-until-done
  finally:
    manager.uninstall
  // The discovery service is the root of its own RPC infrastructure. It
  // stays installed until process exit, as it does during firmware shutdown.
  exit 0

class TestImage extends ContainerImage:
  id/uuid.Uuid
  stops/int := 0

  constructor manager/ContainerManager id/string:
    this.id = uuid.Uuid.parse id
    super manager

  spawn container/Container arguments/any -> int:
    return container.id

  flags -> int:
    return ContainerService.FLAG-RUN-CRITICAL

  stop-all -> none:
    stops++
    manager.on-image-stop-all_ this

  delete -> none:
    unreachable
