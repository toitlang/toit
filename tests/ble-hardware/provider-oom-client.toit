// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ..ble-service-provider-restart-test as fixture
import expect show *
import system.containers

main:
  // Host startup images are critical. Start the bundled provider explicitly
  // so its failure can be observed without terminating the client firmware.
  candidates := containers.images.filter: | image/containers.ContainerImage |
    image.flags == 0
  expect-equals 1 candidates.size
  provider := containers.start candidates.first.id
  try:
    fixture.run --oom --external-provider
    expect-equals 1 provider.wait
    print "BLE_PROVIDER_OOM COMPLETE non-critical=true provider-exit=1"
  finally:
    provider.close
