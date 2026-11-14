// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox
import esp32
import system.containers

// Deep sleep (HALT 2) terminates the sandboxed process instead of the device.
main args:
  sandbox-test args --exit=containers.EXIT-DEVICE-HALT: | arguments/Map |
    esp32.deep-sleep (Duration --ms=100)
