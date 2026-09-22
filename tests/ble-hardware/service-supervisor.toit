// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.containers

// The host startup directory marks images critical. Install the failing client
// separately so its expected death does not shut down the provider's VM.
run image/ByteArray:
  writer := containers.ContainerImageWriter image.size
  id := null
  try:
    writer.write image
    id = writer.commit
  finally:
    writer.close
  child := containers.start id
  try:
    code := with-timeout --ms=90_000: child.wait
    if code != 1: throw "UNEXPECTED_CLIENT_EXIT: $code"
    print "BLE_SERVICE_SUPERVISOR COMPLETE client-exit=1"
  finally:
    child.close
    containers.uninstall id
