// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble show *
import expect show *

TEST-SERVICE ::= BleUuid "c6fbc686-fa22-4252-9dd5-092ffd33432c"

main:
  adapter := Adapter
  central := adapter.central

  central.scan --duration=(Duration --s=3): | device/RemoteScannedDevice |
    if device.data.service_classes.contains TEST-SERVICE:
      unreachable

  adapter.close
