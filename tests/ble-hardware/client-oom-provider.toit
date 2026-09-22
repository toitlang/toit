// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import system.containers
import ..ble-service-multiclient-exit-test as fixture

main:
  candidates := containers.images.filter: | image/containers.ContainerImage |
    image.flags == 0
  expect-equals 1 candidates.size
  application/containers.Container? := null
  try:
    fixture.run:
      application = containers.start candidates.first.id
    expect-equals 1 application.wait
    print "BLE_CLIENT_OOM COMPLETE non-critical=true client-exit=1 subscription-released=true survivor-reads=2 slot-reused=true controller-opens=1"
  finally:
    if application: application.close
